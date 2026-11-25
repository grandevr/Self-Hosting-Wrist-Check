package uk.debil.status;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** Complication tap: ask Wear OS to request fresh data right away (complication and tile). */
public class RefreshReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        Refresh.all(context);
    }
}
