#if DEBUG
import Foundation

/// Local interaction fixtures only. They neither contact Google nor submit
/// account data; the binding VM supplies an isolated WebView and store.
enum GoogleBooksDebugFixtures {
    static let login = document(body: formBody, script: formScript)

    static let blank = """
    <!doctype html><html lang="en"><head>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; form-action 'none'">
    </head><body></body></html>
    """

    /// The native Sign In fixture action clicks [data-fixture-sign-in] or
    /// invokes openGoogleBooksFixtureLogin(). WebKit must keep its popup
    /// configuration/opener so this document can fill the blank window.
    static let popup: String = {
        let childDocument = javaScriptString(login)
        return document(
            body: """
            <h1>Google Play Books fixture</h1>
            <p>This local page tests a sign-in popup. No account is needed.</p>
            <a href="about:blank" data-fixture-sign-in>Sign in</a>
            <p id="fixture-popup-status" role="status"></p>
            """,
            script: #"""
            window.openGoogleBooksFixtureLogin = function () {
              var popup = window.open('about:blank', 'googlebooks-fixture-login');
              if (!popup) {
                document.getElementById('fixture-popup-status').textContent = 'Popup was not opened';
                return false;
              }
              popup.document.open();
              popup.document.write(\#(childDocument));
              popup.document.close();
              return true;
            };
            document.querySelector('[data-fixture-sign-in]').addEventListener('click', function (event) {
              event.preventDefault();
              window.openGoogleBooksFixtureLogin();
            });
            """#
        )
    }()

    private static let formBody = """
    <h1>Google sign-in fixture</h1>
    <p>Local form only. Use synthetic input; nothing is sent.</p>
    <form id="fixture-login-form" autocomplete="off">
      <label for="fixture-email">Email</label>
      <input id="fixture-email" name="email" type="email" aria-label="Email"
             autocomplete="off" autocapitalize="none" spellcheck="false">
      <label for="fixture-password">Password</label>
      <input id="fixture-password" name="password" type="password" aria-label="Password"
             autocomplete="off">
      <button type="submit">Continue</button>
    </form>
    """

    private static let formScript = #"""
    document.getElementById('fixture-login-form').addEventListener('submit', function (event) {
      event.preventDefault();
      var result = document.createElement('p');
      result.id = 'fixture-submitted';
      result.setAttribute('role', 'status');
      result.textContent = 'Form submitted locally';
      event.currentTarget.replaceWith(result);
    });
    """#

    private static func document(body: String, script: String) -> String {
        #"""
        <!doctype html><html lang="en"><head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy"
              content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; form-action 'none'">
        <style>
          * { box-sizing: border-box; }
          body { margin: 0; padding: 24px; min-height: 100vh; background: #fff;
                 color: #24272b; font: 17px -apple-system, sans-serif; }
          h1 { margin: 0 0 12px; font-size: 23px; }
          p { line-height: 1.5; color: #60646b; }
          form { display: grid; gap: 12px; max-width: 440px; margin-top: 24px; }
          label { font-size: 15px; font-weight: 600; }
          input { width: 100%; min-height: 48px; padding: 12px;
                  font: inherit; border: 1px solid #aeb4bd; border-radius: 8px; }
          button, a { min-height: 48px; padding: 12px 18px; border: 0;
                      border-radius: 8px; background: #1a73e8; color: white;
                      font: inherit; text-decoration: none; text-align: center; }
          a { display: inline-block; }
          button { margin-top: 8px; }
        </style></head><body>
        \#(body)
        <script>\#(script)</script>
        </body></html>
        """#
    }

    private static func javaScriptString(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value])
        let array = String(decoding: data, as: UTF8.self)
        // An HTML parser must never see the child's closing script tag inside
        // the outer script, even though it is a JavaScript string literal.
        return String(array.dropFirst().dropLast())
            .replacingOccurrences(of: "<", with: "\\u003c")
    }
}
#endif
