    func testAuditColdRestartDoesNotRetainPreviouslyConfirmedPro() throws {
        let beforeRestart = ProManager.makeForTesting()
        apply(try activeStatus(), to: beforeRestart)
        XCTAssertTrue(beforeRestart.isPro)
        let afterRestart = ProManager.makeForTesting()
        afterRestart.setLocalStoreKitForTesting(true)
        apply(nil, to: afterRestart)
        XCTExpectFailure("Audit: a fresh manager loses the last confirmed account entitlement while status is unavailable") {
            XCTAssertTrue(afterRestart.isPro)
        }
        apply(try activeStatus(), to: afterRestart)
        XCTAssertTrue(afterRestart.isPro)
    }
