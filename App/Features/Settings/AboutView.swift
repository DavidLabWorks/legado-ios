import SwiftUI
import UIKit

enum AppIdentity {
    static let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "喵阅"
    static let author = "DavidLabWorks"
    static let authorURL = URL(string: "https://github.com/\(author)")!
    static let projectURL = authorURL.appendingPathComponent("legado-ios")
    static let feedbackURL = URL(string: "https://t.me/maioreader")!
}

struct AboutView: View {
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—" }
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—" }
    private var diagnosticSummary: String {
        "\(AppIdentity.name) \(version) (\(build))\niOS \(UIDevice.current.systemVersion)\n数据库版本 \(LegadoDatabase.schemaVersion)"
    }

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                appCard
                projectSection
                policySection
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 28)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(ReadingTheme.settingsCanvas)
        .readingPageTitle("关于")
    }

    private var appCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(AppIdentity.name)
                        .font(.system(.largeTitle, design: .serif).weight(.bold))
                    Text("读小说、听书、整理网页")
                        .font(.subheadline.weight(.medium))
                    Text("兼容阅读书源的 iOS 阅读应用")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.72))
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                if !typeSize.isAccessibilitySize {
                    Image("BrandIcon")
                        .resizable().scaledToFit()
                        .frame(width: 112, height: 112)
                        .blendMode(.screen)
                        .accessibilityHidden(true)
                }
            }
            .padding(20)

            Rectangle().fill(.white.opacity(0.16)).frame(height: 1)
            HStack(spacing: 8) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: typeSize.isAccessibilitySize ? 1 : 3), alignment: .leading, spacing: 10) {
                    fact("版本", version)
                    fact("构建", build)
                    fact("系统", "iOS \(UIDevice.current.systemVersion)")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ReadingShareLink(item: diagnosticSummary) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.body.weight(.medium))
                        .frame(width: 44, height: 44)
                        .background(.white.opacity(0.1), in: Circle())
                }
                .fixedSize()
                .accessibilityLabel("分享版本信息")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(.white.opacity(0.045))
        }
        .foregroundStyle(.white)
        .background(LinearGradient(colors: [Color(white: 0.15), .black], startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.white.opacity(0.72))
            Text(value).font(.system(.subheadline, design: .monospaced).weight(.medium))
        }
        .accessibilityElement(children: .combine)
    }

    private var projectSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("项目与社区").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                ReadingShareLink(item: AppIdentity.projectURL) {
                    Label("分享地址", systemImage: "square.and.arrow.up")
                        .font(.footnote.weight(.medium))
                        .frame(minHeight: 44)
                }
                .accessibilityLabel("分享项目地址")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 10) {
                projectLink("项目源码", detail: "legado-ios", icon: "chevron.left.forwardslash.chevron.right", url: AppIdentity.projectURL)
                projectLink("个人主页", detail: AppIdentity.author, icon: "person.crop.circle", url: AppIdentity.authorURL)
            }
            Link(destination: AppIdentity.feedbackURL) {
                HStack(spacing: 12) {
                    Image(systemName: "paperplane")
                        .font(.title3.weight(.medium))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("反馈讨论").font(.subheadline.weight(.semibold))
                        Text("Telegram · @maioreader").font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary).accessibilityHidden(true)
                }
                .padding(14)
                .background { ReadingCardBackground(cornerRadius: 16) }
                .contentShape(Rectangle())
            }
            Text("IPA 可从项目仓库的 release 目录获取，并自行签名安装。")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func projectLink(_ title: String, detail: String, icon: String, url: URL) -> some View {
        Link(destination: url) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: icon).font(.title3.weight(.medium))
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                .accessibilityHidden(true)
                .padding(.bottom, 10)
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background { ReadingCardBackground(cornerRadius: 16) }
        }
    }

    private var policySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("许可与隐私").font(.headline).accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                policyLink("开源许可", icon: "doc.text", detail: "GPL-3.0") { OpenSourceLicensesView() }
                Divider().padding(.leading, 34)
                policyLink("免责协议", icon: "text.book.closed") { policyPage("免责协议") { disclaimer } }
                Divider().padding(.leading, 34)
                policyLink("数据与隐私", icon: "hand.raised") { policyPage("数据与隐私") { privacy } }
            }
            .padding(.horizontal, 16)
            .background { ReadingCardBackground(cornerRadius: 18) }
        }
    }

    private func policyLink(_ title: String, icon: String, detail: String? = nil, @ViewBuilder destination: () -> some View) -> some View {
        NavigationLink(destination: destination()) {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 22).accessibilityHidden(true)
                Text(title)
                Spacer(minLength: 0)
                if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary).accessibilityHidden(true)
            }
            .font(.subheadline)
            .padding(.vertical, 6)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(title)
        .accessibilityValue(detail ?? "")
    }

    private func policyPage(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16, content: content)
                .frame(maxWidth: 640, alignment: .leading)
                .padding(20)
        }
        .frame(maxWidth: .infinity)
        .lineSpacing(5)
        .textSelection(.enabled)
        .background(ReadingTheme.canvas)
        .readingPageTitle(title)
    }

    @ViewBuilder private var disclaimer: some View {
        Text("\(AppIdentity.name)不提供、内置或分发网络书源，也不提供在线书库。书源由用户自行从网络公开分享获取，或自行编写后导入；在线书籍及订阅内容由对应的第三方网站提供。")
        Text("书籍正文、封面、简介等内容的版权归原作者或合法权利人所有。书源可被导入、内容可被访问，不代表已获得版权授权；请仅在获得授权或法律允许的范围内使用，并支持正版阅读。")
        Text("第三方书源及其内容不受本应用控制，可能因网站调整、网络环境等原因失效。本应用不保证第三方内容的准确性、完整性、安全性或书源的持续可用性，请自行核实来源。")
        Text("用户应对自行导入的书源及使用行为负责，遵守适用法律法规和来源网站的使用规则，不得利用本应用侵犯他人权益、传播违法内容或未经授权复制、分发作品。")
        Text("如发现涉嫌侵权内容，请停止访问、删除相关书源及本地缓存，并向内容来源网站反馈。本协议不免除任何一方依法应承担的责任。")
    }

    @ViewBuilder private var privacy: some View {
        Text("书架、阅读进度、书源和诊断日志保存在本机。导入书源、阅读在线内容和刷新订阅时，会连接相应来源的网站。")
        Text("应用不会自动上传诊断日志；可在日志页面手动导出。")
        Text("应用不提供内置网络书源或在线书库。请使用你有权访问的内容与书源。")
    }
}

private struct OpenSourceLicensesView: View {
    var body: some View {
        ReadingPageList {
            license("\(AppIdentity.name) / Legado", resource: "Legado-LICENSE", detail: "GNU GPL v3")
            license("SwiftSoup", resource: "SwiftSoup-LICENSE", detail: "MIT License")
            license("Kanna", resource: "Kanna-LICENSE", detail: "MIT License")
            license("KSPlayer 与 FFmpegKit", resource: "Legado-LICENSE", detail: "GNU GPL v3")
            license("Readium 及其依赖", resource: "Readium-LICENSE", detail: "组件、依赖与字体许可证")
            license("ZIPFoundation", resource: "ZIPFoundation-LICENSE", detail: "MIT License")
        }.readingPageTitle("开源许可")
    }

    private func license(_ title: String, resource: String, detail: String) -> some View {
        NavigationLink {
            ScrollView {
                Text((Bundle.main.url(forResource: resource, withExtension: "txt")
                    .flatMap { try? String(contentsOf: $0, encoding: .utf8) }) ?? "许可文件无法读取")
                    .font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding()
            }.readingPageTitle(title)
        } label: { ReadingLabeledContent(title, value: detail) }
    }
}
