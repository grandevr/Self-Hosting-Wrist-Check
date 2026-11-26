package uk.debil.status

import android.os.Bundle
import android.text.format.DateFormat
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.wear.compose.foundation.lazy.TransformingLazyColumn
import androidx.wear.compose.foundation.lazy.rememberTransformingLazyColumnState
import androidx.wear.compose.material3.AppScaffold
import androidx.wear.compose.material3.ListHeader
import androidx.wear.compose.material3.MaterialTheme
import androidx.wear.compose.material3.ScreenScaffold
import androidx.wear.compose.material3.SurfaceTransformation
import androidx.wear.compose.material3.Text
import androidx.wear.compose.material3.lazy.rememberTransformationSpec
import androidx.wear.compose.material3.lazy.transformedHeight
import java.util.Calendar
import java.util.Locale

/**
 * One service's detail: state and since when, Kuma's last message, response time with a small
 * graph, 24h uptime and certificate expiry. Everything comes from the status.json the list
 * already has (passed in the Intent), so opening it costs no request. Items can be hidden in
 * Settings; items the server didn't send are left out.
 */
class DetailActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val name = intent.getStringExtra(EXTRA_NAME).orEmpty()
        val detail = intent.getStringExtra(EXTRA_DETAIL)?.let { Detail.parse(it) }
        val checked = intent.getStringExtra(EXTRA_CHECKED).orEmpty()
        val shown = DetailItem.entries.filter { it.isOn(this) }.toSet()
        val use24h = DateFormat.is24HourFormat(this)
        setContent {
            StatusTheme {
                DetailScreen(name, detail, checked, shown, use24h)
            }
        }
    }

    companion object {
        const val EXTRA_NAME = "name"
        const val EXTRA_DETAIL = "detail"
        const val EXTRA_CHECKED = "checked"
    }
}

@Composable
private fun DetailScreen(name: String, d: Detail?, checked: String, shown: Set<DetailItem>, use24h: Boolean) {
    val listState = rememberTransformingLazyColumnState()
    val spec = rememberTransformationSpec()
    AppScaffold {
        ScreenScaffold(scrollState = listState) { contentPadding ->
            TransformingLazyColumn(
                state = listState,
                contentPadding = contentPadding,
                modifier = Modifier.fillMaxSize(),
            ) {
                item {
                    ListHeader(Modifier.transformedHeight(this, spec), transformation = SurfaceTransformation(spec)) {
                        Text(name, maxLines = 2, textAlign = TextAlign.Center)
                    }
                }
                if (d == null) {
                    item { Caption("No detail for this service", Modifier.transformedHeight(this, spec)) }
                    return@TransformingLazyColumn
                }

                if (DetailItem.STATE in shown && d.state.isNotEmpty()) {
                    item {
                        Column(Modifier.fillMaxWidth().transformedHeight(this, spec), horizontalAlignment = Alignment.CenterHorizontally) {
                            Text(d.state.uppercase(Locale.ROOT), style = MaterialTheme.typography.displaySmall, color = stateColor(d.state))
                            val since = sinceText(d, use24h)
                            if (since.isNotEmpty()) Caption(since)
                        }
                    }
                }

                // Kuma's public status page API usually leaves the message out, so no switch: shown only when present.
                if (d.msg.isNotEmpty()) {
                    item {
                        Caption(d.msg, Modifier.padding(top = 6.dp).transformedHeight(this, spec), MaterialTheme.colorScheme.onSurface)
                    }
                }

                if (DetailItem.PING in shown && (d.ping != Detail.NONE || d.state == "down")) {
                    item {
                        Line(
                            "Response",
                            if (d.ping != Detail.NONE) "${d.ping} ms" else "no answer",
                            Modifier.padding(top = 8.dp).transformedHeight(this, spec),
                        )
                    }
                }

                if (DetailItem.GRAPH in shown && d.pings.size >= 2) {
                    item { Sparkline(d.pings, Modifier.padding(horizontal = 18.dp, vertical = 4.dp).transformedHeight(this, spec)) }
                }

                if (DetailItem.UPTIME in shown && !d.up24.isNaN()) {
                    item {
                        val color = when {
                            d.up24 >= 99.0 -> StatusColors.Up
                            d.up24 >= 95.0 -> StatusColors.Slow
                            else -> StatusColors.Down
                        }
                        Line("Uptime 24h", formatPercent(d.up24), Modifier.padding(top = 4.dp).transformedHeight(this, spec), color)
                    }
                }

                if (DetailItem.CERT in shown && d.cert != Detail.NONE) {
                    item {
                        val (text, color) = when {
                            d.cert < 0 -> "expired" to StatusColors.Down
                            d.cert <= 7 -> "${d.cert} days" to StatusColors.Down
                            d.cert <= 21 -> "${d.cert} days" to StatusColors.Slow
                            else -> "${d.cert} days" to StatusColors.Up
                        }
                        Line("Certificate", text, Modifier.padding(top = 4.dp).transformedHeight(this, spec), color)
                    }
                }

                if (checked.isNotEmpty()) {
                    item { Caption("Checked $checked", Modifier.padding(top = 8.dp).transformedHeight(this, spec)) }
                }
            }
        }
    }
}

/** "Label   value" on one centred line. */
@Composable
private fun Line(label: String, value: String, modifier: Modifier = Modifier, valueColor: Color = Color.Unspecified) {
    Column(modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
        Text(label, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(
            value,
            style = MaterialTheme.typography.titleMedium,
            color = if (valueColor == Color.Unspecified) MaterialTheme.colorScheme.onSurface else valueColor,
        )
    }
}

/** Response times as a line, oldest on the left. Checks with no answer are red ticks along the bottom. */
@Composable
private fun Sparkline(pings: IntArray, modifier: Modifier = Modifier) {
    val values = pings.filter { it != Detail.NONE }
    val lineColor = MaterialTheme.colorScheme.primary
    val desc = if (values.isEmpty()) "No answers in the last ${pings.size} checks"
        else "Response times, ${values.min()} to ${values.max()} ms over ${pings.size} checks"
    Canvas(modifier.fillMaxWidth().height(40.dp).semantics { contentDescription = desc }) {
        val n = pings.size
        val step = size.width / (n - 1)
        val lo = values.minOrNull() ?: 0
        val hi = values.maxOrNull() ?: 1
        val range = (hi - lo).coerceAtLeast(1).toFloat()
        val tick = 4.dp.toPx()
        val top = 2.dp.toPx()
        val bottom = size.height - tick - 2.dp.toPx()
        val path = Path()
        var drawing = false
        for (i in 0 until n) {
            val x = i * step
            val p = pings[i]
            if (p == Detail.NONE) {
                drawLine(StatusColors.Down, Offset(x, size.height - tick), Offset(x, size.height), strokeWidth = 2.dp.toPx(), cap = StrokeCap.Round)
                drawing = false
                continue
            }
            val y = if (hi == lo) (top + bottom) / 2 else bottom - (p - lo) / range * (bottom - top)
            if (drawing) path.lineTo(x, y) else path.moveTo(x, y)
            drawing = true
        }
        drawPath(path, lineColor, style = Stroke(width = 2.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
    }
}

private fun stateColor(state: String): Color = when (state) {
    "up" -> StatusColors.Up
    "down" -> StatusColors.Down
    else -> StatusColors.Slow
}

private fun formatPercent(p: Double): String =
    if (p >= 99.995) "100%" else String.format(Locale.UK, "%.2f%%", p)

/** "since 14:02 · 2 h 14 min", "since before 3 Dec 20:00", or "". */
private fun sinceText(d: Detail, use24h: Boolean): String {
    if (d.since <= 0) return ""
    val ms = d.since * 1000
    val then = Calendar.getInstance().apply { timeInMillis = ms }
    val now = Calendar.getInstance()
    val sameDay = then.get(Calendar.YEAR) == now.get(Calendar.YEAR) &&
        then.get(Calendar.DAY_OF_YEAR) == now.get(Calendar.DAY_OF_YEAR)
    val time = if (use24h) "HH:mm" else "h:mm a"
    val pattern = if (sameDay) time else "d MMM $time"
    val at = java.text.SimpleDateFormat(pattern, Locale.getDefault()).format(java.util.Date(ms))
    if (d.before) return "since before $at"
    val mins = ((System.currentTimeMillis() - ms) / 60_000).coerceAtLeast(0)
    val dur = when {
        mins < 60 -> "$mins min"
        mins < 48 * 60 -> "${mins / 60} h ${mins % 60} min"
        else -> "${mins / (24 * 60)} days"
    }
    return "since $at · $dur"
}
