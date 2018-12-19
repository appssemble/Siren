//
//  Siren.swift
//  Siren
//
//  Created by Arthur Sabintsev on 1/3/15.
//  Copyright (c) 2015 Sabintsev iOS Projects. All rights reserved.
//

import UIKit

/// The Siren Class. A singleton that is initialized using the `shared` constant.
public final class Siren: NSObject {
    /// Return results or errors obtained from performing a version check with Siren.
    public typealias ResultsHandler = (Results?, KnownError?) -> Void

    /// The Siren singleton. The main point of entry to the Siren library.
    public static let shared = Siren()

    /// The debug flag, which is disabled by default.
    /// When enabled, a stream of `print()` statements are logged to your console when a version check is performed.
    public lazy var debugEnabled: Bool = false

    /// The manager that controls the App Store API that is
    /// used to fetch the latest version of the app.
    ///
    /// Defaults to the US App Store.
    public lazy var apiManager: APIManager = .default

    /// The manager that controls the update alert's string localization and tint color.
    ///
    /// Defaults the string's lange localization to the user's device localization.
    public lazy var presentationManager: PresentationManager = .default

    /// The manager that controls the type of alert that should be displayed
    /// and how often an alert should be displayed dpeneding on the type
    /// of update that is available relative to the installed version of the app
    /// (e.g., different rules for major, minor, patch and revision updated can be used).
    ///
    /// Defaults to performing a version check once a day with an alert that allows
    /// the user to skip updating the app until the next time the app becomes active or
    /// skipping the update all together until another version is released.
    public lazy var rulesManager: RulesManager = .default

    /// The current version of your app that is available for download on the App Store
    internal lazy var currentAppStoreVersion: String = ""

    /// The current installed version of your app.
    internal lazy var currentInstalledVersion: String? = Bundle.version()

    /// The retained `NotificationCenter` observer that listens for `UIApplication.didBecomeActiveNotification` notifications.
    internal var didBecomeActiveObserver: NSObjectProtocol?

    /// The last date that an alert was presented to the user.
    private var alertPresentationDate: Date?

    /// The App Store's unique identifier for an app.
    private var appID: Int?

    /// The completion handler used to return the results or errors returned by Siren.
    private var resultsHandler: ResultsHandler?

    /// The initialization method.
    private override init() {
        alertPresentationDate = UserDefaults.alertPresentationDate
    }
}

// MARK: - Public Functionality

public extension Siren {
    ///
    ///
    /// - Parameter handler:
    func wail(completion handler: ResultsHandler?) {
        resultsHandler = handler
        addObservers()
    }

    /// Launches the AppStore in two situations when the user clicked the `Update` button in the UIAlertController modal.
    ///
    /// This function is marked `public` as a convenience for those developers who decide to build a custom alert modal
    /// instead of using Siren's prebuilt update alert.
    func launchAppStore() {
        guard let appID = appID,
            let url = URL(string: "https://itunes.apple.com/app/id\(appID)") else {
                resultsHandler?(nil, .malformedURL)
                return
        }

        DispatchQueue.main.async {
            if #available(iOS 10.0, *) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            } else {
                UIApplication.shared.openURL(url)
            }
        }
    }
}

// MARK: - Networking

extension Siren {
    func performVersionCheck() {
        apiManager.performVersionCheckRequest { [weak self] (lookupModel, error) in
            guard let self = self else { return }
            guard let lookupModel = lookupModel, error == nil else {
                self.resultsHandler?(nil, error)
                return
            }

            self.analyze(model: lookupModel)
        }
    }

    private func analyze(model: LookupModel) {
        // Check if the latest version is compatible with current device's version of iOS.
        guard DataParser.isUpdateCompatibleWithDeviceOS(for: model) else {
            resultsHandler?(nil, .appStoreOSVersionUnsupported)
            return
        }

        // Check and store the App ID .
        guard let appID = model.results.first?.appID else {
            resultsHandler?(nil, .appStoreAppIDFailure)
            return
        }
        self.appID = appID

        // Check and store the current App Store version.
        guard let currentAppStoreVersion = model.results.first?.version else {
            resultsHandler?(nil, .appStoreVersionArrayFailure)
            return
        }
        self.currentAppStoreVersion = currentAppStoreVersion

        // Check if the App Store version is newer than the currently installed version.
        guard DataParser.isAppStoreVersionNewer(installedVersion: currentInstalledVersion, appStoreVersion: currentAppStoreVersion) else {
            resultsHandler?(nil, .noUpdateAvailable)
            return
        }

        // Check the release date of the current version.
        guard let currentVersionReleaseDate = model.results.first?.currentVersionReleaseDate,
            let daysSinceRelease = Date.days(since: currentVersionReleaseDate) else {
                resultsHandler?(nil, .currentVersionReleaseDate)
                return
        }

        // Check if applicaiton has been released for the amount of days defined by the app consuming Siren.
        guard daysSinceRelease >= rulesManager.releasedForDays else {
            resultsHandler?(nil, .releasedTooSoon(daysSinceRelease: daysSinceRelease,
                                                     releasedForDays: rulesManager.releasedForDays))
            return
        }

        determineIfAlertPresentationRulesAreSatisfied(forLookupModel: model)
    }
}

// MARK: - Alert Presentation

private extension Siren {
    func determineIfAlertPresentationRulesAreSatisfied(forLookupModel model: LookupModel) {
        // Did the user:
        // - request to skip being prompted with version update alerts for a specific version
        // - and is the latest App Store update the same version that was requested?
        if let previouslySkippedVersion = UserDefaults.storedSkippedVersion,
            let currentInstalledVersion = currentInstalledVersion,
            !currentAppStoreVersion.isEmpty,
            currentAppStoreVersion != previouslySkippedVersion {
            resultsHandler?(nil, .skipVersionUpdate(installedVersion: currentInstalledVersion, appStoreVersion: currentAppStoreVersion))
                return
        }

        let updateType = DataParser.parse(installedVersion: currentInstalledVersion, appStoreVersion: currentAppStoreVersion)
        let rules = rulesManager.loadRulesForUpdateType(updateType)

        if rules.frequency == .immediately {
            presentAlert(withRules: rules, model: model, andUpdateType: updateType)
        } else if UserDefaults.shouldPerformVersionCheckOnSubsequentLaunch {
            UserDefaults.shouldPerformVersionCheckOnSubsequentLaunch = false
            presentAlert(withRules: rules, model: model, andUpdateType: updateType)
        } else {
            guard let alertPresentationDate = alertPresentationDate else {
                presentAlert(withRules: rules, model: model, andUpdateType: updateType)
                return
            }
            if Date.days(since: alertPresentationDate) >= rules.frequency.rawValue {
                presentAlert(withRules: rules, model: model, andUpdateType: updateType)
            } else {
                resultsHandler?(nil, .recentlyCheckedVersion)
            }
        }
    }

    func presentAlert(withRules rules: Rules, model: LookupModel, andUpdateType updateType: RulesManager.UpdateType) {
        presentationManager.presentAlert(withRules: rules, forCurrentAppStoreVersion: currentAppStoreVersion) { [weak self] (alertAction, error) in
            guard let self = self else { return }
            let results = Results(alertAction: alertAction ?? .unknown,
                                  localization: self.presentationManager.localization,
                                  lookupModel: model,
                                  updateType: updateType)
            self.resultsHandler?(results, error)
        }
    }
}

// MARK: - Helpers

private extension Siren {
    func addObservers() {
        guard didBecomeActiveObserver == nil else { return }
        didBecomeActiveObserver = NotificationCenter
            .default
            .addObserver(forName: UIApplication.didBecomeActiveNotification,
                         object: nil,
                         queue: nil) { [weak self] _ in
                            guard let self = self else { return }
                            self.performVersionCheck()
        }
    }
}
