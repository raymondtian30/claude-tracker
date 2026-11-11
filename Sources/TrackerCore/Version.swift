import Foundation

/// App name, version and credits.
///
/// The version follows Semantic Versioning (https://semver.org): MAJOR.MINOR.PATCH.
/// Bump MAJOR for changes that break existing installs or saved data, MINOR for
/// new features, PATCH for fixes. 2.0.0 marks the redesign on top of the
/// original 1.x app; 3.0.0 the rewrite in Swift; 3.1.0 limit names, Fable and new limits, effort levels; 3.2.0 effort switch, interactive chart, folder names, currency; 3.3.0 own data folder, fast clicks, all-time and custom chart; 3.4.0 Stop and Quit for each Claude session; 3.5.0 apply button for custom dates, exact sessions, smoother unfolding; 3.6.0 Custom range tab with two calendars, chat titles, Quit all with confirmation.
public enum Version {
    public static let appName = "Claude Tracker"
    public static let version = "3.7.0"

    public static let originalAuthor = "BrodyKretz"
    public static let forkAuthor = "Raymond Tian"
    public static let repoURL = "https://github.com/raymondtian30/claude-tracker"
}
