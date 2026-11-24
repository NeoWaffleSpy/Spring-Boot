package com.eventmapper.eclipse;

import com.eventmapper.core.EventMapper;
import com.eventmapper.core.MapperConfig;
import com.eventmapper.core.json.GraphJsonWriter;
import com.eventmapper.core.model.Graph;
import com.eventmapper.core.model.Node;
import com.eventmapper.core.page.PageRenderer;
import org.eclipse.core.commands.AbstractHandler;
import org.eclipse.core.commands.ExecutionEvent;
import org.eclipse.core.runtime.IPath;
import org.eclipse.core.runtime.IProgressMonitor;
import org.eclipse.core.runtime.IStatus;
import org.eclipse.core.runtime.OperationCanceledException;
import org.eclipse.core.runtime.Platform;
import org.eclipse.core.runtime.Status;
import org.eclipse.core.runtime.jobs.Job;
import org.eclipse.jdt.core.IJavaProject;
import org.eclipse.jface.dialogs.ErrorDialog;
import org.eclipse.jface.dialogs.MessageDialog;
import org.eclipse.swt.SWT;
import org.eclipse.swt.widgets.Display;
import org.eclipse.swt.widgets.FileDialog;
import org.eclipse.swt.widgets.Shell;
import org.eclipse.ui.handlers.HandlerUtil;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

/**
 * Project &gt; Export Event Map...: maps the selected Java projects (all open Java projects when
 * none is selected) in a background job and writes the map as an HTML page (the same page as
 * {@code Event_mapper.sh}) or as JSON, depending on the file name chosen.
 */
public class ExportEventMapHandler extends AbstractHandler {

    private static final String PLUGIN_ID = "com.eventmapper.eclipse";

    @Override
    public Object execute(ExecutionEvent event) {
        Shell shell = HandlerUtil.getActiveShell(event);
        List<IJavaProject> projects = Projects.selectedOrAll(HandlerUtil.getCurrentSelection(event));
        if (projects.isEmpty()) {
            MessageDialog.openInformation(shell, "Event Mapper", "There is no open Java project to map.");
            return null;
        }
        IPath root = Projects.commonRoot(projects);
        String name = Projects.name(projects, root);

        FileDialog dialog = new FileDialog(shell, SWT.SAVE);
        dialog.setText("Export Event Map");
        dialog.setFilterExtensions(new String[]{"*.html", "*.json"});
        dialog.setFilterNames(new String[]{"Event map page (*.html)", "Event map data (*.json)"});
        dialog.setFilterPath(root.toOSString());
        dialog.setFileName(name + ".html");
        dialog.setOverwrite(true);
        String target = dialog.open();
        if (target == null) {
            return null;
        }
        Path out = Path.of(target);
        boolean html = !target.toLowerCase().endsWith(".json");
        log(IStatus.INFO, "Export started: " + projects.size() + " project(s) under " + root.toOSString() + " -> " + out, null);

        Job job = new Job("Building event map") {
            @Override
            protected IStatus run(IProgressMonitor monitor) {
                monitor.beginTask("Building event map", IProgressMonitor.UNKNOWN);
                try {
                    JdtCodeModel model = new JdtCodeModel(projects, root);
                    model.setMonitor(monitor);
                    Graph graph = new EventMapper(MapperConfig.defaults()).analyse(model);
                    String json = GraphJsonWriter.write(graph);
                    Files.writeString(out, html ? PageRenderer.render(name, json) : json, StandardCharsets.UTF_8);
                    String summary = summary(graph, out);
                    log(IStatus.INFO, summary.replace('\n', ' '), null);
                    show(shell, () -> MessageDialog.openInformation(shell, "Event Mapper", summary));
                } catch (OperationCanceledException e) {
                    log(IStatus.INFO, "Export cancelled", null);
                    return Status.CANCEL_STATUS;
                } catch (Throwable e) { // Errors too (NoClassDefFoundError...), so nothing fails silently
                    IStatus error = log(IStatus.ERROR, "Event map failed: " + e, e);
                    show(shell, () -> ErrorDialog.openError(shell, "Event Mapper", "The event map could not be built.", error));
                } finally {
                    monitor.done();
                }
                // failures are already logged and shown; an ERROR result would show a second dialog
                return Status.OK_STATUS;
            }
        };
        job.setUser(true); // shows the progress dialog, which can be sent to the background
        job.schedule();
        return null;
    }

    /** Writes to the Error Log view (Window > Show View > General > Error Log). */
    private static IStatus log(int severity, String message, Throwable e) {
        IStatus status = new Status(severity, PLUGIN_ID, message, e);
        Platform.getLog(ExportEventMapHandler.class).log(status);
        return status;
    }

    /** Runs a dialog on the UI thread, on the original window if it is still open. */
    private static void show(Shell shell, Runnable dialog) {
        Display display = shell != null && !shell.isDisposed() ? shell.getDisplay() : Display.getDefault();
        display.asyncExec(dialog);
    }

    private static String summary(Graph g, Path out) {
        Map<String, Integer> kinds = new TreeMap<>();
        for (Node n : g.nodes()) {
            kinds.merge(n.kind, 1, Integer::sum);
        }
        StringBuilder sb = new StringBuilder("Event map written to\n").append(out).append("\n\n")
                .append(g.files).append(" Java files, ").append(g.components.size()).append(" components\n");
        kinds.forEach((k, v) -> sb.append(v).append(' ').append(k).append('\n'));
        return sb.append(g.edges().size()).append(" links, ").append(g.unresolved.size()).append(" unresolved").toString();
    }
}
