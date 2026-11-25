package uk.debil.status;

import android.content.ComponentName;
import android.content.Context;

import androidx.wear.tiles.TileService;
import androidx.wear.watchface.complications.datasource.ComplicationDataSourceUpdateRequester;

/** Asks Wear OS to re-request both the complication and the tile. */
final class Refresh {
    private Refresh() {}

    static void all(Context context) {
        ComplicationDataSourceUpdateRequester
                .create(context, new ComponentName(context, StatusDataSource.class))
                .requestUpdateAll();
        TileService.getUpdater(context).requestUpdate(StatusTileService.class);
    }
}
