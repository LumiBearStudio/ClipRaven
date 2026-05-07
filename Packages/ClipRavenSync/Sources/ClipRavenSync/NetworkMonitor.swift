import Foundation
import Network

/// 네트워크 종류를 동기로 read 가능한 추상화.
///
/// Production: `NWPathMonitorBasedProvider` 사용 (NWPathMonitor 래핑).
/// Tests: mock 주입 (셀룰러/Wi-Fi 가상 시나리오).
///
/// 왜 protocol:
/// - `NWPathMonitor` 는 system framework 라 unit test 에서 강제로 셀룰러로
///   만들 수 없음. Mapper.encode 같은 호출 측에 protocol 만 의존시켜
///   테스트 mock 주입 가능.
public protocol NetworkStateProvider: Sendable {
    /// 현재 네트워크가 셀룰러인지. 오프라인이면 false (보내기 자체가 실패하므로
    /// 차단 의미 없음).
    var isCellular: Bool { get }

    /// 네트워크 사용 가능 여부. offline 일 때 false.
    var isOnline: Bool { get }
}

/// `NWPathMonitor` 기반 production 구현. 싱글턴 (`monitor.start` 는 한 번만).
public final class NWPathMonitorBasedProvider: NetworkStateProvider, @unchecked Sendable {

    public static let shared = NWPathMonitorBasedProvider()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.lumibear.NetworkMonitor", qos: .utility)

    /// `NWPathMonitor.pathUpdateHandler` 가 background queue 에서 호출되므로
    /// 직접 캐시. `os_unfair_lock` 대신 단순화 — read/write 가 짧은 단순 Bool.
    private var cachedIsCellular = false
    private var cachedIsOnline = true
    private let lock = NSLock()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let cellular = path.usesInterfaceType(.cellular) && path.status == .satisfied
            let online = path.status == .satisfied
            self.lock.lock()
            self.cachedIsCellular = cellular
            self.cachedIsOnline = online
            self.lock.unlock()
        }
        monitor.start(queue: queue)
    }

    public var isCellular: Bool {
        lock.lock(); defer { lock.unlock() }
        return cachedIsCellular
    }

    public var isOnline: Bool {
        lock.lock(); defer { lock.unlock() }
        return cachedIsOnline
    }
}

/// 글로벌 registry — 앱 시작 시점 1회 등록. 미등록이면 `defaultProvider`
/// (안전 fallback: "셀룰러 아님" 반환 = 가드 통과 = 기존 동작 보존) 사용.
public enum NetworkStateRegistry {
    nonisolated(unsafe) public private(set) static var current: NetworkStateProvider =
        DefaultProvider()

    public static func register(_ provider: NetworkStateProvider) {
        current = provider
    }

    /// 미등록 시 fallback. 모든 환경을 "non-cellular online" 으로 간주 →
    /// 셀룰러 가드가 통과되어 기존 sync 동작 그대로 유지. 안전 default.
    private struct DefaultProvider: NetworkStateProvider {
        var isCellular: Bool { false }
        var isOnline: Bool { true }
    }
}

/// 사용자 옵션 + 현재 네트워크 결합 — "큰 binary 를 지금 보내도 되나?"
///
/// 호출 시점: `SyncRecordMapper.encode` — 매 클립 인코딩마다 동기로 평가됨.
/// 가벼운 read 만 수행해야 함.
public enum NetworkPolicy {
    public static func canSendLargeAssets(
        provider: NetworkStateProvider = NetworkStateRegistry.current,
        settings: ImageSyncSettings.Snapshot = ImageSyncSettings.current()
    ) -> Bool {
        guard provider.isOnline else { return false }
        if !provider.isCellular { return true }       // Wi-Fi / 유선 / 알 수 없음
        return settings.cellularAllowed              // 셀룰러일 땐 사용자 옵션
    }
}
