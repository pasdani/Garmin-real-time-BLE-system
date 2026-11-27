import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

//
// MonitorDelegate.mc — Buttons of the V5 main screen.
//
// The session is the open app, so START has no function here (alerts are
// confirmed with START on their own screen, AlertDelegate).
//
//   UP     previous alert mode  (as edge / silent / sound / vibrate)
//   DOWN   next alert mode
//   BACK   exits, always after confirmation: exiting closes the session and
//          stops radio, data and alerts
//
class MonitorDelegate extends WatchUi.BehaviorDelegate {

    private var _app as MonitorApp;

    function initialize(app as MonitorApp) {
        BehaviorDelegate.initialize();
        _app = app;
    }

    // On the FR255 the UP button arrives as onPreviousPage, DOWN as onNextPage.
    function onPreviousPage() as Boolean {
        _app.stepAlertMode(-1);
        return true;
    }

    function onNextPage() as Boolean {
        _app.stepAlertMode(1);
        return true;
    }

    function onBack() as Boolean {
        WatchUi.pushView(new WatchUi.Confirmation("Stop and exit?"),
                         new MonitorExitDelegate(), WatchUi.SLIDE_IMMEDIATE);
        return true;
    }
}

class MonitorExitDelegate extends WatchUi.ConfirmationDelegate {

    function initialize() {
        ConfirmationDelegate.initialize();
    }

    function onResponse(response) as Boolean {
        if (response == WatchUi.CONFIRM_YES) {
            System.exit();
        }
        return true;
    }
}
