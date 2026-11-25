package uk.debil.status;

import android.content.ComponentName;
import android.content.Context;

import androidx.wear.watchface.complications.datasource.ComplicationDataSourceUpdateRequester;

/** Asks Wear OS to re-request the complication data right away. */
final class Refresh {
    private Refresh() {}

    static void complication(Context context) {
        ComplicationDataSourceUpdateRequester
                .create(context, new ComponentName(context, StatusDataSource.class))
                .requestUpdateAll();
    }
}
