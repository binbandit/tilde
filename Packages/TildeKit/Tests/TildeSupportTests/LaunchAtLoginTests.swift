import Foundation
import Testing
@testable import TildeSupport

@MainActor
struct LaunchAtLoginTests {
    @MainActor
    final class Service {
        var status: LaunchAtLogin.Status = .notRegistered
        var registrations = 0
        var unregistrations = 0
        var registrationResult: LaunchAtLogin.Status = .enabled
        var failure: Failure?
        var beforeRegister: (() async -> Void)?

        func preference() -> LaunchAtLogin {
            LaunchAtLogin {
                self.status
            } register: {
                self.registrations += 1
                await self.beforeRegister?()
                if let failure = self.failure { throw failure }
                self.status = self.registrationResult
            } unregister: {
                self.unregistrations += 1
                if let failure = self.failure { throw failure }
                self.status = .notRegistered
            }
        }
    }

    struct Failure: LocalizedError {
        var errorDescription: String? { "The app's signature is invalid." }
    }

    @Test func openingAndRefreshingDoNotRegister() {
        let service = Service()
        let preference = service.preference()
        preference.refresh()
        #expect(preference.status == .notRegistered)
        #expect(!preference.isRegistered)
        #expect(!preference.isEnabled)
        #expect(service.registrations == 0)
        #expect(service.unregistrations == 0)
    }

    @Test func explicitChangesUseTheSystemAndSurviveRecreation() async {
        let service = Service()
        let preference = service.preference()
        await preference.setEnabled(true)
        #expect(service.registrations == 1)
        #expect(preference.isEnabled)
        #expect(service.preference().isEnabled)
        await preference.setEnabled(false)
        #expect(service.unregistrations == 1)
        #expect(preference.status == .notRegistered)
        #expect(!service.preference().isEnabled)
    }

    @Test func pendingApprovalIsNotEnabledAndCanBeCancelled() async {
        let service = Service()
        service.registrationResult = .requiresApproval
        let preference = service.preference()
        await preference.setEnabled(true)
        #expect(preference.status == .requiresApproval)
        #expect(preference.isRegistered)
        #expect(!preference.isEnabled)
        await preference.setEnabled(false)
        #expect(service.unregistrations == 1)
        #expect(!preference.isRegistered)
    }

    @Test func refreshReflectsApprovalAndRevocationOutsideTheApp() {
        let service = Service()
        service.status = .requiresApproval
        let preference = service.preference()
        service.status = .enabled
        preference.refresh()
        #expect(preference.isEnabled)
        service.status = .requiresApproval
        preference.refresh()
        #expect(!preference.isEnabled)
        service.status = .notRegistered
        preference.refresh()
        #expect(!preference.isRegistered)
        #expect(service.registrations == 0)
        #expect(service.unregistrations == 0)
    }

    @Test func registrationErrorsDoNotPretendTheSettingChanged() async {
        let service = Service()
        service.failure = Failure()
        let preference = service.preference()
        await preference.setEnabled(true)
        #expect(preference.status == .notRegistered)
        #expect(preference.error == "The app's signature is invalid.")
        #expect(!preference.isUpdating)
        service.failure = nil
        await preference.setEnabled(true)
        #expect(preference.isEnabled)
        #expect(preference.error == nil)
    }

    @Test func unregisterErrorsKeepTheActualEnabledState() async {
        let service = Service()
        service.status = .enabled
        service.failure = Failure()
        let preference = service.preference()
        await preference.setEnabled(false)
        #expect(preference.isEnabled)
        #expect(preference.error != nil)
        #expect(!preference.isUpdating)
    }

    @Test func anErrorStillReadsBackTheSystemState() async {
        let service = Service()
        service.failure = Failure()
        service.beforeRegister = { service.status = .requiresApproval }
        let preference = service.preference()
        await preference.setEnabled(true)
        #expect(preference.status == .requiresApproval)
        #expect(preference.isRegistered)
        #expect(!preference.isEnabled)
        #expect(preference.error != nil)
        service.status = .enabled
        preference.refresh()
        #expect(preference.isEnabled)
        #expect(preference.error == nil)
    }

    @Test(arguments: [LaunchAtLogin.Status.notFound, .unknown])
    func unavailableStatusIsNotReportedAsEnabled(_ status: LaunchAtLogin.Status) {
        let service = Service()
        service.status = status
        let preference = service.preference()
        #expect(preference.status == status)
        #expect(!preference.isEnabled)
        #expect(!preference.isRegistered)
        #expect(service.registrations == 0)
    }

    @Test func staleAndRepeatedRequestsDoNotRegisterTwice() async {
        let service = Service()
        let preference = service.preference()
        service.status = .enabled
        await preference.setEnabled(true)
        #expect(service.registrations == 0)
        service.status = .requiresApproval
        await preference.setEnabled(true)
        #expect(service.registrations == 0)
        #expect(!preference.isEnabled)
        service.status = .notRegistered
        await preference.setEnabled(false)
        #expect(service.unregistrations == 0)
    }

    @Test func changesAreSerializedWhileTheServiceIsBusy() async {
        let service = Service()
        let preference = service.preference()
        service.beforeRegister = {
            #expect(preference.isUpdating)
            await preference.setEnabled(true)
            #expect(service.registrations == 1)
        }
        await preference.setEnabled(true)
        #expect(preference.isEnabled)
        #expect(!preference.isUpdating)
    }
}
