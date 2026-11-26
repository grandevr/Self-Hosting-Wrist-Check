package uk.debil.status

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.wear.compose.foundation.lazy.TransformingLazyColumn
import androidx.wear.compose.foundation.lazy.TransformingLazyColumnScope
import androidx.wear.compose.foundation.lazy.rememberTransformingLazyColumnState
import androidx.wear.compose.material3.AppScaffold
import androidx.wear.compose.material3.ButtonDefaults
import androidx.wear.compose.material3.CircularProgressIndicator
import androidx.wear.compose.material3.EdgeButton
import androidx.wear.compose.material3.EdgeButtonSize
import androidx.wear.compose.material3.FilledTonalButton
import androidx.wear.compose.material3.Icon
import androidx.wear.compose.material3.ListHeader
import androidx.wear.compose.material3.MaterialTheme
import androidx.wear.compose.material3.OutlinedButton
import androidx.wear.compose.material3.ScreenScaffold
import androidx.wear.compose.material3.SurfaceTransformation
import androidx.wear.compose.material3.Text
import androidx.wear.compose.material3.lazy.rememberTransformationSpec
import androidx.wear.compose.material3.lazy.transformedHeight
import java.util.concurrent.Executors

/**
 * Scrollable list of everything that's down or slow, then (if the server sends them) what's up.
 * If status.json has "groups", shows collapsible categories instead ("Media / UP 3 • DOWN 1").
 * Opened by tapping the complication (or from the app list). Opening it, or tapping "Refresh",
 * also refreshes the complication right away. Scrolls with touch or the rotating bezel.
 */
class ProblemsActivity : ComponentActivity() {
    private var status by mutableStateOf<Status?>(null)
    private var loading by mutableStateOf(false)

    /** Categories the user opened (true) or closed (false) by hand, so a refresh keeps their choice. */
    private val toggled = mutableStateMapOf<String, Boolean>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            StatusTheme {
                ProblemsScreen(
                    status = status,
                    loading = loading,
                    isOpen = { g -> toggled[g.name] ?: g.problems.isNotEmpty() },
                    onToggle = { g, open -> toggled[g.name] = !open },
                    onRefresh = { load() },
                    onSettings = { startActivity(Intent(this, SetupActivity::class.java)) },
                )
            }
        }
    }

    override fun onResume() {
        super.onResume()
        load()
    }

    private fun load() {
        if (loading) return
        loading = true
        Refresh.complication(applicationContext)
        EXECUTOR.execute {
            val s = StatusFetcher.fetch(applicationContext)
            runOnUiThread {
                loading = false
                if (!isFinishing && !isDestroyed) status = s
            }
        }
    }

    private companion object {
        val EXECUTOR = Executors.newSingleThreadExecutor()
    }
}

@Composable
private fun ProblemsScreen(
    status: Status?,
    loading: Boolean,
    isOpen: (Group) -> Boolean,
    onToggle: (Group, Boolean) -> Unit,
    onRefresh: () -> Unit,
    onSettings: () -> Unit,
) {
    val listState = rememberTransformingLazyColumnState()
    val spec = rememberTransformationSpec()
    AppScaffold {
        ScreenScaffold(
            scrollState = listState,
            edgeButton = {
                EdgeButton(onClick = onRefresh, buttonSize = EdgeButtonSize.Medium, enabled = !loading) {
                    if (loading) {
                        CircularProgressIndicator(modifier = Modifier.size(24.dp))
                    } else {
                        Icon(painterResource(R.drawable.ic_refresh), contentDescription = "Refresh")
                    }
                }
            },
        ) { contentPadding ->
            TransformingLazyColumn(
                state = listState,
                contentPadding = contentPadding,
                modifier = Modifier.fillMaxSize(),
            ) {
                item {
                    ListHeader(Modifier.transformedHeight(this, spec), transformation = SurfaceTransformation(spec)) {
                        Text("Homelab")
                    }
                }

                if (status == null) {
                    item {
                        Box(Modifier.fillMaxWidth().padding(16.dp), contentAlignment = Alignment.Center) {
                            CircularProgressIndicator(Modifier.size(36.dp))
                        }
                    }
                    return@TransformingLazyColumn
                }

                item { Headline(status, Modifier.transformedHeight(this, spec)) }

                if (status.groups.isNotEmpty()) {
                    for (g in status.groups) {
                        val open = isOpen(g)
                        item(key = "group:" + g.name) {
                            GroupButton(g, open, { onToggle(g, open) }, Modifier.transformedHeight(this, spec), SurfaceTransformation(spec))
                        }
                        if (open) {
                            for (p in g.problems) {
                                item { ServiceRow(p, problemColor(p), Modifier.transformedHeight(this, spec)) }
                            }
                            for (name in g.up) {
                                item { ServiceRow(name, StatusColors.Up, Modifier.transformedHeight(this, spec)) }
                            }
                        }
                    }
                } else {
                    flatList(status, spec)
                }

                val footer = status.footer()
                if (footer.isNotEmpty()) {
                    item { Caption(footer, Modifier.padding(top = 6.dp).transformedHeight(this, spec)) }
                }

                item {
                    val setup = status.kind == Status.Kind.SETUP
                    val modifier = Modifier.fillMaxWidth().padding(top = 6.dp).transformedHeight(this, spec)
                    val icon: @Composable androidx.compose.foundation.layout.BoxScope.() -> Unit = {
                        Icon(painterResource(R.drawable.ic_settings), contentDescription = null)
                    }
                    if (setup) {
                        FilledTonalButton(onClick = onSettings, modifier = modifier,
                            transformation = SurfaceTransformation(spec), icon = icon,
                            label = { Text("Set up") })
                    } else {
                        OutlinedButton(onClick = onSettings, modifier = modifier,
                            transformation = SurfaceTransformation(spec), icon = icon,
                            label = { Text("Settings") })
                    }
                }
            }
        }
    }
}

/** Big status word ("ALL UP", "2 DOWN"), coloured by severity. */
@Composable
private fun Headline(status: Status, modifier: Modifier = Modifier) {
    Column(modifier.fillMaxWidth().padding(bottom = 6.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            text = status.shortText(),
            style = MaterialTheme.typography.displaySmall,
            color = status.headlineColor(),
            textAlign = TextAlign.Center,
        )
    }
}

/** A category: name, "UP n • DOWN n" underneath, and a chevron. Tap to expand or collapse. */
@Composable
private fun GroupButton(
    g: Group,
    open: Boolean,
    onClick: () -> Unit,
    modifier: Modifier,
    transformation: SurfaceTransformation,
) {
    val rotation by animateFloatAsState(if (open) 180f else 0f, label = "chevron")
    val summaryColor = when {
        g.downCount() > 0 -> StatusColors.Down
        g.slowCount() > 0 -> StatusColors.Slow
        else -> StatusColors.Up
    }
    FilledTonalButton(
        onClick = onClick,
        modifier = modifier.fillMaxWidth().semantics {
            contentDescription = g.name + ", " + g.summary() + if (open) ", expanded" else ", collapsed"
        },
        transformation = transformation,
        label = { Text(g.name, maxLines = 1) },
        secondaryLabel = { Text(g.summary(), color = summaryColor, maxLines = 1) },
        icon = {
            Icon(
                painterResource(R.drawable.ic_expand),
                contentDescription = null,
                modifier = Modifier.size(ButtonDefaults.IconSize).rotate(rotation),
            )
        },
    )
}

/** No categories from the server: problems, then working services. */
private fun TransformingLazyColumnScope.flatList(
    status: Status,
    spec: androidx.wear.compose.material3.lazy.TransformationSpec,
) {
    val lines = status.detailLines()
    if (lines.isEmpty() && status.up.isEmpty() && status.kind == Status.Kind.OK) {
        item { Caption("Everything is up", Modifier.transformedHeight(this, spec)) }
    }
    if (status.kind == Status.Kind.PROBLEMS) {
        for (p in lines) item { ServiceRow(p, problemColor(p), Modifier.transformedHeight(this, spec)) }
    } else {
        for (line in lines) item { Caption(line, Modifier.transformedHeight(this, spec), MaterialTheme.colorScheme.onSurface) }
    }
    if (status.up.isNotEmpty()) {
        item {
            ListHeader(Modifier.transformedHeight(this, spec), transformation = SurfaceTransformation(spec)) {
                Text("Up · " + status.up.size)
            }
        }
        for (name in status.up) {
            item { ServiceRow(name, StatusColors.Up, Modifier.transformedHeight(this, spec)) }
        }
    }
}
