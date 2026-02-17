static UIWindow *QTGetKeyWindow(void) {
    UIApplication *app = UIApplication.sharedApplication;

    // iOS 13+ (und damit iOS 15–17): über Scenes gehen
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;

            UIWindowScene *ws = (UIWindowScene *)scene;

            // Erst KeyWindow suchen
            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow) return w;
            }
            // Fallback: erste Window
            if (ws.windows.count > 0) return ws.windows.firstObject;
        }

        // Letzter Fallback: irgendeine Scene
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            if (ws.windows.count > 0) return ws.windows.firstObject;
        }

        return nil;
    }

    // < iOS 13 (für deinen “iOS 15–17” Plan eigentlich egal, aber sauber)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return app.keyWindow ?: app.windows.firstObject;
#pragma clang diagnostic pop
}
