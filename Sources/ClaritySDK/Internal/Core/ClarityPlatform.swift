/// The platform discriminator the page and backend key on. One value, three
/// protocol fields: the widget URL's `nativeMode` param, the handshake's
/// `x-os` header and the `setDeviceToken` bridge payload's `platform`.
enum ClarityPlatform {
    static let identifier = "ios"
}
