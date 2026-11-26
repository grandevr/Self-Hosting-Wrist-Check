package uk.debil.status;

import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.graphics.drawable.Icon;
import android.os.RemoteException;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.wear.watchface.complications.data.ComplicationData;
import androidx.wear.watchface.complications.data.ComplicationText;
import androidx.wear.watchface.complications.data.ComplicationType;
import androidx.wear.watchface.complications.data.LongTextComplicationData;
import androidx.wear.watchface.complications.data.MonochromaticImage;
import androidx.wear.watchface.complications.data.PlainComplicationText;
import androidx.wear.watchface.complications.data.ShortTextComplicationData;
import androidx.wear.watchface.complications.datasource.ComplicationDataSourceService;
import androidx.wear.watchface.complications.datasource.ComplicationRequest;

import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Complication data source showing the homelab status from status.json.
 *
 * SHORT_TEXT: text "ALL UP" / "2 DOWN" / "SLOW" / "STALE" / "OFFLINE" / "KUMA",
 *             title = check time (HH:MM) when all is up, otherwise the first problem's service name.
 * LONG_TEXT:  text "All up" or the first problem label, title "+N more" or "Checked HH:MM".
 * Tapping the complication opens ProblemsActivity (full list), which also refreshes the complication.
 * Before the app is set up it shows "SETUP" / "TAP HERE" and tapping opens SetupActivity.
 */
public class StatusDataSource extends ComplicationDataSourceService {
    private static final String TAG = "DebilStatus";
    private static final ExecutorService EXECUTOR = Executors.newSingleThreadExecutor();
    /**
     * Reuse a result this young instead of asking the server again. The 15-minute period is far
     * longer, so scheduled updates always fetch; this only absorbs bursts of extra requests.
     */
    private static final long REUSE_MS = 60_000;

    @Override
    public void onComplicationRequest(@NonNull ComplicationRequest request,
                                      @NonNull ComplicationRequestListener listener) {
        final ComplicationType type = request.getComplicationType();
        final Context ctx = getApplicationContext();
        EXECUTOR.execute(() -> {
            Status status = StatusFetcher.fetch(ctx, REUSE_MS);
            try {
                listener.onComplicationData(build(ctx, type, status));
            } catch (RemoteException e) {
                Log.w(TAG, "Couldn't deliver complication data", e);
            }
        });
    }

    @Nullable
    @Override
    public ComplicationData getPreviewData(@NonNull ComplicationType type) {
        return build(this, type, Status.preview());
    }

    @Nullable
    static ComplicationData build(Context ctx, ComplicationType type, Status s) {
        MonochromaticImage icon = new MonochromaticImage.Builder(
                Icon.createWithResource(ctx, R.drawable.ic_server)).build();
        ComplicationText description = text(s.description());
        PendingIntent tap = tapIntent(ctx, s.kind == Status.Kind.SETUP);

        if (type == ComplicationType.SHORT_TEXT) {
            return new ShortTextComplicationData.Builder(text(s.shortText()), description)
                    .setTitle(text(s.shortTitle()))
                    .setMonochromaticImage(icon)
                    .setTapAction(tap)
                    .build();
        }
        if (type == ComplicationType.LONG_TEXT) {
            return new LongTextComplicationData.Builder(text(s.longText()), description)
                    .setTitle(text(s.longTitle()))
                    .setMonochromaticImage(icon)
                    .setTapAction(tap)
                    .build();
        }
        return null;
    }

    private static ComplicationText text(String s) {
        return new PlainComplicationText.Builder(s).build();
    }

    /** Opens the problem list, or the setup screen while the app isn't set up yet. */
    private static PendingIntent tapIntent(Context ctx, boolean needsSetup) {
        Intent intent = new Intent(ctx, needsSetup ? SetupActivity.class : ProblemsActivity.class);
        return PendingIntent.getActivity(ctx, needsSetup ? 1 : 0, intent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    }
}
