package uk.debil.status;

import android.content.BroadcastReceiver;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;

import androidx.wear.watchface.complications.datasource.ComplicationDataSourceUpdateRequester;

/** Complication tap: ask Wear OS to request fresh data from StatusDataSource right away. */
public class RefreshReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        ComplicationDataSourceUpdateRequester
                .create(context, new ComponentName(context, StatusDataSource.class))
                .requestUpdateAll();
    }
}
