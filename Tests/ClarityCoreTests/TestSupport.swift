@testable import ClaritySDK

/// Shared neutral config fixture for the core tests — override only the
/// fields a test actually pins.
func makeTestConfig(
    organizationId: String = "42",
    integrationKey: String = "test-key",
    baseUrl: String = "https://chat.example.com",
    channelHost: String? = nil
) -> ClarityConfig {
    ClarityConfig(
        organizationId: organizationId,
        integrationKey: integrationKey,
        baseUrl: baseUrl,
        channelHost: channelHost
    )
}
