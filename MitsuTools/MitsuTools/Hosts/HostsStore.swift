import Foundation
import Observation

/// プロファイルを JSON ファイル（~/.config/mitsutools/hosts.json）で管理する。
/// dotfiles で管理したい人は、このファイルをリンクすればよい。
@MainActor
@Observable
final class HostsStore {
    static let shared = HostsStore()

    private(set) var profiles: [HostsProfile] = []
    /// 読み書きに失敗したときの理由
    private(set) var lastError: String?

    var url: URL { ConfigFile.configDirectory.appending(path: "mitsutools/hosts.json") }

    private struct Payload: Codable {
        var profiles: [HostsProfile]
    }

    @ObservationIgnored private var fileWatcher: DispatchSourceFileSystemObject?

    private init() {}

    // MARK: 読み込み・保存

    func load() {
        guard let data = try? Data(contentsOf: url) else {
            profiles = []
            watch()
            return
        }
        do {
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            profiles = payload.profiles
            lastError = nil
        } catch {
            lastError = "読み込めませんでした: \(error.localizedDescription)"
        }
        watch()
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // シンボリックリンク（dotfiles）ならリンク先に書く
            let target = url.resolvingSymlinksInPath()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(Payload(profiles: profiles))
            try data.write(to: target, options: .atomic)
            lastError = nil
        } catch {
            lastError = "書き込めませんでした: \(error.localizedDescription)"
        }
        watch()
    }

    // MARK: 編集

    @discardableResult
    func add(name: String = "") -> HostsProfile {
        let profile = HostsProfile(name: name, entries: [])
        profiles.append(profile)
        save()
        return profile
    }

    func remove(_ profile: HostsProfile) {
        profiles.removeAll { $0.id == profile.id }
        save()
    }

    func update(_ profile: HostsProfile) {
        guard let i = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[i] = profile
        save()
    }

    func profile(named name: String) -> HostsProfile? {
        profiles.first { $0.name == name }
    }

    // MARK: 監視

    /// ファイルを外で編集されたときに読み直す（dotfiles で管理している人向け）。
    private func watch() {
        fileWatcher?.cancel()
        let path = url.resolvingSymlinksInPath().path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete], queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                // 書き込みが終わるのを少し待ってから読む
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    MainActor.assumeIsolated { HostsStore.shared.load() }
                }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileWatcher = source
    }
}
