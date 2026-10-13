# G10 O’Reilly Mac parity verification

2026-10-05 用户明确取消本轮 O’Reilly 测试：N/A（本轮范围排除），停止等待账号及后续验收。以下保留历史证据，不表示书籍流程已通过，也不删除产品入口。

## Actual normal-app observations

- Library Sources retains existing Kindle 23, Google Books 5, Kobo 5, WeRead 65 synced entries; O’Reilly is correctly Not connected. Existing stores and sessions were not cleared.
- Personal-account action navigated to the official `oreilly.com/member/login/` form with email input and the provider’s institutional access link. No account was entered and no trial/subscription was created.
- In the 470×400-point connection sheet the original bottom overlay hid the O’Reilly title/support description. Mac now arranges branding and actions in one scrollable vertical layout. Both personal and institution actions are reachable, with no overlap. iOS retains its existing presentation.
- Close/Cancel text was visibly truncated to `Cl…` in compact Catalyst navigation bars. A shared Mac icon dismissal button retains its localized accessibility name and Escape shortcut; adopted by Library Sources, O’Reilly connection and institution form. Actual Close returned to sources, then home; Escape from the institution form returned only to the connection page.
- Institution form shows Peninsula Library System, the provider directory, URL field and Open. Empty Open is disabled. `https://example.invalid/library` is rejected locally with an accurate message; form stays open and no navigation occurs.
- Toolbar login-method Menu did not respond to accessibility click, pointer click, or keyboard attempts on the normal Catalyst sheet. Mac now uses a Button and native option dialog; actual replay opened both choices and Cancel, and selecting School or library opened the complete institution form. iOS keeps Menu and shares the same actions.

## Evidence and pending work

Candidate and isolated OReillyContractTests + ReaderAppearanceTests results are under `g10-oreilly-ui/`. Final selection passed **Mac 33/33 and iPad 33/33**, no failures or skips. Rebuilt/signed normal Mac app passed the entry, dismissal, invalid-link and replacement-dialog flows. These fixture contracts do not prove an actual authenticated shelf, book playback, pagination or restore. User was asked asynchronously whether a personal/institutional account is available; no answer yet.


Actual final replay also opened the official `oreilly.com/library-access/` page with institution input. The replacement login-method button still opened its options while the WKWebView was loaded; Cancel retained that page. No institution was selected or authenticated.
