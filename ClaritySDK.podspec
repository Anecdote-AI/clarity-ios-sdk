# CocoaPods distribution of the Clarity iOS support SDK.
#
# SPM (Package.swift) stays the primary channel. This exists so CocoaPods-based
# hosts can consume the same source — notably Flutter and React Native
# plugins, which cannot declare a dependency on an SPM-only package.
#
# The version is READ from ClarityVersion.swift rather than restated here, so
# the release tag, the Swift constant and the pod version cannot drift (the
# same reason scripts/check-version.sh guards the tag).
#
# This file is mirrored verbatim into the public repo by ios-sdk-release.yml's
# allowlist, so every path below must resolve in BOTH trees — they share the
# same layout (Package.swift + Sources/ + Tests/ + README + CHANGELOG at root).

Pod::Spec.new do |s|
  version_file = File.join(__dir__, 'Sources', 'ClaritySDK', 'ClarityVersion.swift')
  version_match = File.read(version_file).match(/static let current = "([^"]+)"/)
  raise "Could not read ClarityVersion.current from #{version_file}" if version_match.nil?

  s.name     = 'ClaritySDK'
  s.version  = version_match[1]
  s.summary  = 'In-app customer support chat for iOS — the Clarity support widget.'
  s.description = <<~DESC
    Native-feel support chat: a pre-warmed WKWebView presented as a bottom
    sheet or full screen, with user identity, typed custom attributes, product
    events, an unread badge and APNs push routing. Zero third-party
    dependencies.
  DESC

  s.homepage = 'https://github.com/Anecdote-AI/clarity-ios-sdk'
  s.author   = { 'Clarity' => 'support@onclarity.com' }
  # Declared inline rather than as a :file. LICENSE does ship, but the release
  # workflow mirrors it conditionally (`[ -f LICENSE ] && rsync ... || true`),
  # so a :file reference would depend on a file the publish step is allowed to
  # skip — and a missing license fails `pod spec lint` against a trunk that is
  # append-only. Inline is unconditional.
  s.license  = {
    :type => 'Proprietary',
    :text => 'Copyright Anecdote AI. All rights reserved.',
  }

  # Published versions are append-only, and the pod resolves from the public
  # mirror's tag — the same commit SPM consumers get.
  s.source = {
    :git => 'https://github.com/Anecdote-AI/clarity-ios-sdk.git',
    :tag => "v#{s.version}",
  }

  # Mirrors Package.swift: iOS 15+, Swift 5.10, one source-only library target.
  s.ios.deployment_target = '15.0'
  s.swift_versions        = ['5.10']
  s.source_files          = 'Sources/ClaritySDK/**/*.swift'
  s.frameworks            = 'UIKit', 'WebKit', 'UserNotifications'
end
