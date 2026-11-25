package uk.debil.status;

import androidx.annotation.NonNull;
import androidx.concurrent.futures.CallbackToFutureAdapter;
import androidx.wear.protolayout.ActionBuilders;
import androidx.wear.protolayout.ColorBuilders;
import androidx.wear.protolayout.DeviceParametersBuilders;
import androidx.wear.protolayout.DimensionBuilders;
import androidx.wear.protolayout.LayoutElementBuilders;
import androidx.wear.protolayout.ModifiersBuilders;
import androidx.wear.protolayout.ResourceBuilders;
import androidx.wear.protolayout.TimelineBuilders;
import androidx.wear.tiles.RequestBuilders;
import androidx.wear.tiles.TileBuilders;
import androidx.wear.tiles.TileService;

import com.google.common.util.concurrent.ListenableFuture;

import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Tile listing the current problems. Tiles can't scroll, so it shows as many problems as fit
 * on the screen and then "+N more". Tapping the tile opens {@link ProblemsActivity} with the full list.
 */
public class StatusTileService extends TileService {
    private static final String RESOURCES_VERSION = "1";
    private static final long FRESHNESS_MS = 15 * 60 * 1000L;
    private static final ExecutorService EXECUTOR = Executors.newSingleThreadExecutor();

    private static final int GREY = 0xFFAAAAAA;
    private static final int WHITE = 0xFFFFFFFF;
    private static final float ROW_DP = 22f;

    @NonNull
    @Override
    protected ListenableFuture<TileBuilders.Tile> onTileRequest(
            @NonNull RequestBuilders.TileRequest request) {
        final DeviceParametersBuilders.DeviceParameters device = request.getDeviceConfiguration();
        return CallbackToFutureAdapter.getFuture(completer -> {
            EXECUTOR.execute(() -> {
                try {
                    completer.set(buildTile(StatusFetcher.fetch(), device));
                } catch (Throwable t) {
                    completer.setException(t);
                }
            });
            return "StatusTile";
        });
    }

    @NonNull
    @Override
    protected ListenableFuture<ResourceBuilders.Resources> onTileResourcesRequest(
            @NonNull RequestBuilders.ResourcesRequest request) {
        return CallbackToFutureAdapter.getFuture(completer -> {
            completer.set(new ResourceBuilders.Resources.Builder()
                    .setVersion(RESOURCES_VERSION).build());
            return "StatusTileResources";
        });
    }

    private TileBuilders.Tile buildTile(Status s, DeviceParametersBuilders.DeviceParameters device) {
        LayoutElementBuilders.Layout layout =
                new LayoutElementBuilders.Layout.Builder().setRoot(root(s, device)).build();
        return new TileBuilders.Tile.Builder()
                .setResourcesVersion(RESOURCES_VERSION)
                .setFreshnessIntervalMillis(FRESHNESS_MS)
                .setTileTimeline(new TimelineBuilders.Timeline.Builder()
                        .addTimelineEntry(new TimelineBuilders.TimelineEntry.Builder()
                                .setLayout(layout).build())
                        .build())
                .build();
    }

    /** How many list rows fit between the header and footer on this (round) screen. */
    static int maxRows(int screenHeightDp) {
        float usable = screenHeightDp * 0.66f - 70f; // header + status + footer take ~70dp
        return Math.max(2, (int) (usable / ROW_DP));
    }

    private LayoutElementBuilders.LayoutElement root(
            Status s, DeviceParametersBuilders.DeviceParameters device) {
        int widthDp = device.getScreenWidthDp() > 0 ? device.getScreenWidthDp() : 225;
        int heightDp = device.getScreenHeightDp() > 0 ? device.getScreenHeightDp() : 225;

        LayoutElementBuilders.Column.Builder col = new LayoutElementBuilders.Column.Builder()
                .setWidth(DimensionBuilders.expand())
                .setHorizontalAlignment(LayoutElementBuilders.HORIZONTAL_ALIGN_CENTER)
                .addContent(text("HOMELAB", 12, GREY, false))
                .addContent(text(s.shortText(), 26, s.color(), true));

        List<String> lines = s.detailLines();
        int rows = maxRows(heightDp);
        int shown = lines.size() <= rows ? lines.size() : rows - 1;
        if (!lines.isEmpty()) col.addContent(spacer(4));
        for (int i = 0; i < shown; i++) {
            col.addContent(text(lines.get(i), 15, WHITE, false));
        }
        if (shown < lines.size()) {
            col.addContent(text("+" + (lines.size() - shown) + " more", 14, GREY, false));
        }
        String footer = s.footer();
        if (!footer.isEmpty()) {
            col.addContent(spacer(6)).addContent(text(footer, 12, GREY, false));
        }

        ModifiersBuilders.Clickable open = new ModifiersBuilders.Clickable.Builder()
                .setId("open_list")
                .setOnClick(new ActionBuilders.LaunchAction.Builder()
                        .setAndroidActivity(new ActionBuilders.AndroidActivity.Builder()
                                .setPackageName(getPackageName())
                                .setClassName(ProblemsActivity.class.getName())
                                .build())
                        .build())
                .build();

        float side = widthDp * 0.12f;
        return new LayoutElementBuilders.Box.Builder()
                .setWidth(DimensionBuilders.expand())
                .setHeight(DimensionBuilders.expand())
                .setHorizontalAlignment(LayoutElementBuilders.HORIZONTAL_ALIGN_CENTER)
                .setVerticalAlignment(LayoutElementBuilders.VERTICAL_ALIGN_CENTER)
                .setModifiers(new ModifiersBuilders.Modifiers.Builder()
                        .setClickable(open)
                        .setPadding(new ModifiersBuilders.Padding.Builder()
                                .setStart(DimensionBuilders.dp(side))
                                .setEnd(DimensionBuilders.dp(side))
                                .build())
                        .build())
                .addContent(col.build())
                .build();
    }

    private static LayoutElementBuilders.LayoutElement text(
            String value, float sizeSp, int color, boolean bold) {
        LayoutElementBuilders.FontStyle.Builder font = new LayoutElementBuilders.FontStyle.Builder()
                .setSize(DimensionBuilders.sp(sizeSp))
                .setColor(ColorBuilders.argb(color));
        if (bold) font.setWeight(LayoutElementBuilders.FONT_WEIGHT_BOLD);
        return new LayoutElementBuilders.Text.Builder()
                .setText(value)
                .setFontStyle(font.build())
                .setMaxLines(1)
                .setOverflow(LayoutElementBuilders.TEXT_OVERFLOW_ELLIPSIZE)
                .build();
    }

    private static LayoutElementBuilders.LayoutElement spacer(float heightDp) {
        return new LayoutElementBuilders.Spacer.Builder()
                .setHeight(DimensionBuilders.dp(heightDp)).build();
    }
}
