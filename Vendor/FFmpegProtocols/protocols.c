/*
 * This file is part of FFmpeg.
 *
 * FFmpeg is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * FFmpeg is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with FFmpeg; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

// FFmpeg n6.1 libavformat/protocols.c, built into the app so the linker
// resolves the registry here before extracting FFmpegKit's static archive.
#include <string.h>
#include <Libavformat/avio.h>
#include <Libavformat/version.h>
#include <Libavutil/avstring.h>
#include <Libavutil/macros.h>
#include <Libavutil/mem.h>

#if LIBAVFORMAT_VERSION_INT != AV_VERSION_INT(60, 16, 100)
#error Check the protocol list and private URLProtocol layout against the new Libavformat.
#endif

// Private type from the matching libavformat/url.h.
typedef struct URLContext URLContext;
typedef struct URLProtocol {
    const char *name;
    int     (*url_open)( URLContext *h, const char *url, int flags);
    /**
     * This callback is to be used by protocols which open further nested
     * protocols. options are then to be passed to ffurl_open_whitelist()
     * or ffurl_connect() for those nested protocols.
     */
    int     (*url_open2)(URLContext *h, const char *url, int flags, AVDictionary **options);
    int     (*url_accept)(URLContext *s, URLContext **c);
    int     (*url_handshake)(URLContext *c);

    /**
     * Read data from the protocol.
     * If data is immediately available (even less than size), EOF is
     * reached or an error occurs (including EINTR), return immediately.
     * Otherwise:
     * In non-blocking mode, return AVERROR(EAGAIN) immediately.
     * In blocking mode, wait for data/EOF/error with a short timeout (0.1s),
     * and return AVERROR(EAGAIN) on timeout.
     * Checking interrupt_callback, looping on EINTR and EAGAIN and until
     * enough data has been read is left to the calling function; see
     * retry_transfer_wrapper in avio.c.
     */
    int     (*url_read)( URLContext *h, unsigned char *buf, int size);
    int     (*url_write)(URLContext *h, const unsigned char *buf, int size);
    int64_t (*url_seek)( URLContext *h, int64_t pos, int whence);
    int     (*url_close)(URLContext *h);
    int (*url_read_pause)(URLContext *h, int pause);
    int64_t (*url_read_seek)(URLContext *h, int stream_index,
                             int64_t timestamp, int flags);
    int (*url_get_file_handle)(URLContext *h);
    int (*url_get_multi_file_handle)(URLContext *h, int **handles,
                                     int *numhandles);
    int (*url_get_short_seek)(URLContext *h);
    int (*url_shutdown)(URLContext *h, int flags);
    const AVClass *priv_data_class;
    int priv_data_size;
    int flags;
    int (*url_check)(URLContext *h, int mask);
    int (*url_open_dir)(URLContext *h);
    int (*url_read_dir)(URLContext *h, AVIODirEntry **next);
    int (*url_close_dir)(URLContext *h);
    int (*url_delete)(URLContext *h);
    int (*url_move)(URLContext *h_src, URLContext *h_dst);
    const char *default_whitelist;
} URLProtocol;

extern const URLProtocol ff_async_protocol;
extern const URLProtocol ff_cache_protocol;
extern const URLProtocol ff_concat_protocol;
extern const URLProtocol ff_concatf_protocol;
extern const URLProtocol ff_crypto_protocol;
extern const URLProtocol ff_data_protocol;
extern const URLProtocol ff_fd_protocol;
extern const URLProtocol ff_ffrtmpcrypt_protocol;
extern const URLProtocol ff_ffrtmphttp_protocol;
extern const URLProtocol ff_file_protocol;
extern const URLProtocol ff_ftp_protocol;
extern const URLProtocol ff_gopher_protocol;
extern const URLProtocol ff_gophers_protocol;
extern const URLProtocol ff_hls_protocol;
extern const URLProtocol ff_http_protocol;
extern const URLProtocol ff_httpproxy_protocol;
extern const URLProtocol ff_https_protocol;
extern const URLProtocol ff_icecast_protocol;
extern const URLProtocol ff_mmsh_protocol;
extern const URLProtocol ff_mmst_protocol;
extern const URLProtocol ff_md5_protocol;
extern const URLProtocol ff_pipe_protocol;
extern const URLProtocol ff_prompeg_protocol;
extern const URLProtocol ff_rtmp_protocol;
extern const URLProtocol ff_rtmpe_protocol;
extern const URLProtocol ff_rtmps_protocol;
extern const URLProtocol ff_rtmpt_protocol;
extern const URLProtocol ff_rtmpte_protocol;
extern const URLProtocol ff_rtmpts_protocol;
extern const URLProtocol ff_rtp_protocol;
extern const URLProtocol ff_srtp_protocol;
extern const URLProtocol ff_subfile_protocol;
extern const URLProtocol ff_tee_protocol;
extern const URLProtocol ff_tcp_protocol;
extern const URLProtocol ff_tls_protocol;
extern const URLProtocol ff_udp_protocol;
extern const URLProtocol ff_udplite_protocol;
extern const URLProtocol ff_unix_protocol;
extern const URLProtocol ff_libsrt_protocol;
extern const URLProtocol ff_ipfs_gateway_protocol;
extern const URLProtocol ff_ipns_gateway_protocol;

// FFmpegKit 6.1.5 iOS protocol order, with libsmbclient disabled.
static const URLProtocol *const url_protocols[] = {
    &ff_async_protocol,
    &ff_cache_protocol,
    &ff_concat_protocol,
    &ff_concatf_protocol,
    &ff_crypto_protocol,
    &ff_data_protocol,
    &ff_fd_protocol,
    &ff_ffrtmpcrypt_protocol,
    &ff_ffrtmphttp_protocol,
    &ff_file_protocol,
    &ff_ftp_protocol,
    &ff_gopher_protocol,
    &ff_gophers_protocol,
    &ff_hls_protocol,
    &ff_http_protocol,
    &ff_httpproxy_protocol,
    &ff_https_protocol,
    &ff_icecast_protocol,
    &ff_mmsh_protocol,
    &ff_mmst_protocol,
    &ff_md5_protocol,
    &ff_pipe_protocol,
    &ff_prompeg_protocol,
    &ff_rtmp_protocol,
    &ff_rtmpe_protocol,
    &ff_rtmps_protocol,
    &ff_rtmpt_protocol,
    &ff_rtmpte_protocol,
    &ff_rtmpts_protocol,
    &ff_rtp_protocol,
    &ff_srtp_protocol,
    &ff_subfile_protocol,
    &ff_tee_protocol,
    &ff_tcp_protocol,
    &ff_tls_protocol,
    &ff_udp_protocol,
    &ff_udplite_protocol,
    &ff_unix_protocol,
    &ff_libsrt_protocol,
    &ff_ipfs_gateway_protocol,
    &ff_ipns_gateway_protocol,
    NULL
};

const AVClass *ff_urlcontext_child_class_iterate(void **iter)
{
    const AVClass *ret = NULL;
    uintptr_t i;

    for (i = (uintptr_t)*iter; url_protocols[i]; i++) {
        ret = url_protocols[i]->priv_data_class;
        if (ret)
            break;
    }

    *iter = (void*)(uintptr_t)(url_protocols[i] ? i + 1 : i);
    return ret;
}

const char *avio_enum_protocols(void **opaque, int output)
{
    uintptr_t i;

    for (i = (uintptr_t)*opaque; url_protocols[i]; i++) {
        const URLProtocol *p = url_protocols[i];
        if ((output && p->url_write) || (!output && p->url_read)) {
            *opaque = (void*)(uintptr_t)(i + 1);
            return p->name;
        }
    }
    *opaque = NULL;
    return NULL;
}

const AVClass *avio_protocol_get_class(const char *name)
{
    int i = 0;
    for (i = 0; url_protocols[i]; i++) {
        if (!strcmp(url_protocols[i]->name, name))
            return url_protocols[i]->priv_data_class;
    }
    return NULL;
}

const URLProtocol **ffurl_get_protocols(const char *whitelist,
                                        const char *blacklist)
{
    const URLProtocol **ret;
    int i, ret_idx = 0;

    ret = av_calloc(FF_ARRAY_ELEMS(url_protocols), sizeof(*ret));
    if (!ret)
        return NULL;

    for (i = 0; url_protocols[i]; i++) {
        const URLProtocol *up = url_protocols[i];

        if (whitelist && *whitelist && !av_match_name(up->name, whitelist))
            continue;
        if (blacklist && *blacklist && av_match_name(up->name, blacklist))
            continue;

        ret[ret_idx++] = up;
    }

    return ret;
}
