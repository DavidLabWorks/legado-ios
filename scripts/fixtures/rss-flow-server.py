"""Local, synthetic RSS responses for the LegadoRSSFlowUITests scheme."""

import base64
import http.server
import json
from pathlib import Path
import re
import time
import urllib.parse

BASE_URL = "http://127.0.0.1:18763"


class Fixture(http.server.BaseHTTPRequestHandler):
    article_reads = {}
    feed_reads = {}
    served_images = set()

    def do_GET(self):
        parsed = urllib.parse.urlsplit(self.path)
        if parsed.path == "/favicon.ico":
            self.send_error(404)
            return
        query = urllib.parse.parse_qs(parsed.query)
        key = query.get("key", [""])[0]
        page = query.get("page", ["1"])[0]
        if parsed.path == "/media/gesture.m3u8":
            # A VOD playlist can be sought by time even when this response has no byte ranges.
            body = (Path(__file__).with_name("media") / "gesture.m3u8").read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "application/vnd.apple.mpegurl")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if parsed.path in ("/media/gesture.mov", "/media/gesture.mp4", "/media/gesture.ts"):
            clip = Path(__file__).with_name("media") / Path(parsed.path).name
            body = clip.read_bytes()
            requested = re.fullmatch(r"bytes=(\d+)-(\d*)", self.headers.get("Range", ""))
            start = int(requested[1]) if requested else 0
            end = min(int(requested[2]), len(body) - 1) if requested and requested[2] else len(body) - 1
            if start > end:
                self.send_error(416)
                return
            self.send_response(206 if requested else 200)
            self.send_header("Accept-Ranges", "bytes")
            if requested:
                self.send_header("Content-Range", f"bytes {start}-{end}/{len(body)}")
            self.send_header("Content-Type", {".mov": "video/quicktime", ".mp4": "video/mp4", ".ts": "video/mp2t"}[clip.suffix])
            self.send_header("Content-Length", str(end - start + 1))
            self.end_headers()
            self.wfile.write(body[start:end + 1])
            return
        if parsed.path.startswith("/grid/"):
            root = "/".join(parsed.path.split("/")[:3]) + "/"
            titles = ["第二页文章"] if parsed.path.endswith("/page/2/") else [f"文章 {i}" for i in range(20)]
            if len(titles) > 1:
                self.feed_reads[root] = self.feed_reads.get(root, 0) + 1
                if self.feed_reads[root] == 1:
                    time.sleep(3)  # Keep the cold-load indicator observable.
                titles[0] = f"第{self.feed_reads[root]}次首页"
                titles.insert(0, "一段需要换行的文章标题" * 6)
            else:
                time.sleep(2)
            cards = "".join(f'<div class="post grid"><h3><a href="/articles/{title}">{title}</a></h3></div>' for title in titles)
            more = f'<div class="pagination"><li class="next-page"><a href="{root}page/2/">下一頁</a></li></div>' if len(titles) > 1 else ""
            headline = f'<a target="_blank" href="{root}page/2/?from=paper">打开新闻报道</a>' if len(titles) > 1 else ""
            body = f'<html><body>{headline}<div id="posts">{cards}</div>{more}</body></html>'.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if parsed.path == "/wide.png":
            policy = query.get("policy", [""])[0]
            token = query.get("once", [None])[0]
            if token:
                if token in self.served_images:
                    self.send_error(410)
                    return
                self.served_images.add(token)
            if policy == "none" and self.headers.get("Referer"):
                self.send_error(403)
                return
            if policy == "stall":
                time.sleep(30)
            body = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAUAAAAAYAQAAAACjQRkpAAAAEUlEQVR4nGNgGAWjYBQMNwAAA9gAAdPGQ68AAAAASUVORK5CYII=")
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            if token:
                self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if parsed.path == "/source.json":
            self.article_reads.clear()
            self.feed_reads.clear()
            payload = {
                "sourceUrl": BASE_URL,
                "sourceName": "RSS 全流程测试",
                "sortUrl": "全部::" + BASE_URL + "/feed?page={{page}}",
                "searchUrl": BASE_URL + "/feed?key={{key}}&page={{page}}",
                "ruleArticles": "$.items",
                "articleStyle": 3,
                "ruleImage": "$.image",
                "ruleTitle": "$.title",
                "ruleLink": "$.link",
                "ruleContent": "$.content",
                "ruleNextPage": "$.next",
                "preload": True,
            }
            if query.get("legacy"):
                payload.pop("ruleContent")
                payload["ruleDescription"] = "$.description"
        elif parsed.path.startswith("/article/"):
            count = self.article_reads.get(parsed.path, 0) + 1
            self.article_reads[parsed.path] = count
            head = "<head><title>刷新后的网页标题</title></head>" if count > 1 else ""
            payload = {"content": f"<html>{head}<body><p>第{count}次加载的订阅正文</p></body></html>"}
        else:
            title = f"搜索结果 {key} 第{page}页" if key else "首页文章"
            payload = {"items": [{
                "title": title,
                "link": BASE_URL + "/article/" + key + "/" + page,
                "description": "<p>这是用于全流程测试的自造订阅正文。</p>",
            }]}
            if key and page == "1":
                for index in range(2, 21):
                    payload["items"].append({"title": f"结果 {index}", "link": BASE_URL + f"/article/item/{index}"})
                payload["next"] = BASE_URL + "/feed?" + urllib.parse.urlencode({"key": key, "page": 2})
            elif key and page == "2":
                time.sleep(5)
            if not key:
                payload["items"][0]["image"] = BASE_URL + "/wide.png"
                payload["items"].append({"title": "短标题", "link": BASE_URL + "/second", "image": BASE_URL + "/wide.png"})
                visits = self.feed_reads.get(page, 0) + 1
                self.feed_reads[page] = visits
                if visits > 1:
                    payload["items"].append({"title": "下拉刷新后的文章", "link": BASE_URL + "/fresh"})
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    http.server.ThreadingHTTPServer(("127.0.0.1", 18763), Fixture).serve_forever()
