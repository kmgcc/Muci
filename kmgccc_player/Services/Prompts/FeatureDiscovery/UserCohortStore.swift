//
//  UserCohortStore.swift
//  kmgccc_player
//
//  Tells upgraded installs from fresh ones for feature discovery.
//

import Foundation

enum UserCohort: String, Codable, Sendable {
    /// The install existed before feature discovery did.
    case upgraded
    /// A fresh install; discovery waits until the user has settled in.
    case newInstall
}

struct UserCohortProfile: Codable, Equatable, Sendable {
    var cohort: UserCohort
    var firstLaunchDate: Date
    /// Distinct local days ("yyyy-MM-dd") the App was used, newest last.
    var activeDayKeys: [String]
}

/// Establishes the cohort once and keeps a short record of active days.
///
/// The cohort is decided from traces an earlier version leaves behind (install
/// history keys, an existing music library). Reading only a first-launch date
/// would mistake every 2.4.x upgrade for a fresh install.
@MainActor
final class UserCohortStore {
    private static let profileKey = "kmgccc_player.featureDiscovery.cohortProfile"
    /// Only the count matters, up to the largest rule threshold.
    private static let retainedActiveDays = 14

    private let defaults: UserDefaults
    private let calendar: Calendar

    init(defaults: UserDefaults = PromptDefaults.store, calendar: Calendar = .current) {
        self.defaults = defaults
        self.calendar = calendar
    }

    var profile: UserCohortProfile? {
        guard let data = defaults.data(forKey: Self.profileKey) else { return nil }
        return try? JSONDecoder().decode(UserCohortProfile.self, from: data)
    }

    /// Returns the stored profile, creating it on the first call. Later calls
    /// ignore `hasPriorInstallTraces`.
    @discardableResult
    func establish(hasPriorInstallTraces: Bool, now: Date) -> UserCohortProfile {
        if let profile { return profile }
        let profile = UserCohortProfile(
            cohort: hasPriorInstallTraces ? .upgraded : .newInstall,
            firstLaunchDate: now,
            activeDayKeys: [dayKey(for: now)]
        )
        save(profile)
        Log.info("[FeatureDiscovery] cohort established: \(profile.cohort.rawValue)", category: .ui)
        return profile
    }

    func recordActiveDay(_ now: Date) {
        guard var profile else { return }
        let key = dayKey(for: now)
        guard profile.activeDayKeys.last != key, !profile.activeDayKeys.contains(key) else { return }
        profile.activeDayKeys.append(key)
        profile.activeDayKeys = Array(profile.activeDayKeys.suffix(Self.retainedActiveDays))
        save(profile)
    }

    /// Replaces the profile with one installed `installedDaysAgo` days before
    /// `now` and used on each day since. Debug tools and tests.
    func simulate(_ cohort: UserCohort, installedDaysAgo: Int, now: Date) {
        let days = max(0, installedDaysAgo)
        let firstLaunch = calendar.date(byAdding: .day, value: -days, to: now) ?? now
        let activeDays = (0...min(days, Self.retainedActiveDays - 1)).reversed().map { offset in
            dayKey(for: calendar.date(byAdding: .day, value: -offset, to: now) ?? now)
        }
        save(UserCohortProfile(cohort: cohort, firstLaunchDate: firstLaunch, activeDayKeys: activeDays))
    }

    private func save(_ profile: UserCohortProfile) {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        defaults.set(data, forKey: Self.profileKey)
    }

    private func dayKey(for date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
