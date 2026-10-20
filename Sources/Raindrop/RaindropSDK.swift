/// Static identity of this SDK, reported as `$context.library` on every event.
public enum RaindropSDK {
    /// SDK version.
    public static let version = "0.0.7"

    /// Library name.
    public static let libraryName = "raindrop-swift"

    /// OTLP `service.name` for exported spans.
    public static let serviceName = "raindrop.swift-sdk"
}
