import SwiftUI

struct StartupSettingsView: View {
    @AppStorage("auto_refresh") private var autoRefresh = false
    @AppStorage("onlyUpdateRead") private var onlyUpdateRead = false
    @AppStorage("defaultHomePage") private var defaultHomePage: AppTab = .bookshelf

    var body: some View {
        ScrollView {
            startupSettings
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 24)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
        }
        .background(ReadingTheme.settingsCanvas)
        .readingPageTitle("启动管理")
    }

    private var startupSettings: some View {
        ReadingSoftCard {
            VStack(alignment: .leading, spacing: 10) {
                Menu {
                    Picker("启动时打开", selection: $defaultHomePage) {
                        ForEach(AppTab.allCases, id: \.self) { page in
                            Text(page.title).tag(page)
                        }
                    }
                } label: {
                    HStack {
                        Text("启动时打开")
                        Spacer(minLength: 8)
                        Text(defaultHomePage.title).foregroundStyle(.secondary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("启动时打开")
                .accessibilityValue(defaultHomePage.title)
                .accessibilityIdentifier("settings.startupPage")
                Divider()
                Toggle("启动时更新书架", isOn: $autoRefresh)
                    .frame(minHeight: 44)
                if autoRefresh {
                    let scope = onlyUpdateRead ? "已读到最新章的书" : "全部书籍"
                    Menu {
                        Picker("检查范围", selection: $onlyUpdateRead) {
                            Text("全部书籍").tag(false)
                            Text("已读到最新章的书").tag(true)
                        }
                    } label: {
                        HStack {
                            Text("检查范围").foregroundStyle(.secondary)
                            Spacer(minLength: 4)
                            Text(scope)
                            Image(systemName: "chevron.up.chevron.down").font(.caption)
                        }
                        .font(.subheadline)
                        .padding(.leading, 12)
                        .frame(minHeight: 44)
                        .overlay(alignment: .leading) {
                            Capsule().fill(ReadingTheme.separator).frame(width: 2, height: 24)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("检查范围")
                    .accessibilityValue(scope)
                    .accessibilityIdentifier("settings.refreshScope")
                }
            }
            .padding(16)
        }
    }
}
