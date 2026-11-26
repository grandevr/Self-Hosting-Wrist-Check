package uk.debil.status

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.wear.compose.material3.ColorScheme
import androidx.wear.compose.material3.MaterialTheme
import androidx.wear.compose.material3.Text
import androidx.wear.compose.material3.dynamicColorScheme

/** Status colours that sit well on the Material 3 dark surfaces. */
object StatusColors {
    val Up = Color(0xFF8FD9A8)
    val Slow = Color(0xFFFFC566)
    val Down = Color(0xFFFF8A80)
}

/**
 * Material 3 for Wear OS. Uses the watch's dynamic colours (Wear OS 6 picks them from the watch
 * face) when available, else the default Material 3 scheme.
 */
@Composable
fun StatusTheme(content: @Composable () -> Unit) {
    val context = LocalContext.current
    MaterialTheme(colorScheme = dynamicColorScheme(context) ?: ColorScheme(), content = content)
}

/** Colour for a problem label such as "Sonarr DOWN" or "Radarr SLOW". */
fun problemColor(label: String): Color = if (label.endsWith(" DOWN")) StatusColors.Down else StatusColors.Slow

/** Headline colour for the overall status. */
@Composable
internal fun Status.headlineColor(): Color = when (kind) {
    Status.Kind.OK -> StatusColors.Up
    Status.Kind.PROBLEMS -> if (downCount() > 0) StatusColors.Down else StatusColors.Slow
    Status.Kind.OFFLINE -> MaterialTheme.colorScheme.onSurfaceVariant
    else -> StatusColors.Slow
}

/** One service: a coloured dot and its name. Not clickable. */
@Composable
fun ServiceRow(name: String, color: Color, modifier: Modifier = Modifier) {
    Row(
        modifier = modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(8.dp).background(color, CircleShape))
        Spacer(Modifier.width(10.dp))
        Text(
            text = name,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurface,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

/** Centred secondary text (explanations, footers). */
@Composable
fun Caption(text: String, modifier: Modifier = Modifier, color: Color = Color.Unspecified) {
    Text(
        text = text,
        modifier = modifier.fillMaxWidth().padding(horizontal = 8.dp),
        style = MaterialTheme.typography.bodySmall,
        color = if (color == Color.Unspecified) MaterialTheme.colorScheme.onSurfaceVariant else color,
        textAlign = TextAlign.Center,
    )
}
