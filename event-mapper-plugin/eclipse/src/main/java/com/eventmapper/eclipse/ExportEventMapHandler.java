package com.eventmapper.eclipse;

import com.eventmapper.core.EventMapper;
import com.eventmapper.core.MapperConfig;
import com.eventmapper.core.json.GraphJsonWriter;
import com.eventmapper.core.model.Graph;
import com.eventmapper.core.model.Node;
import org.eclipse.core.commands.AbstractHandler;
import org.eclipse.core.commands.ExecutionEvent;
import org.eclipse.core.resources.IProject;
import org.eclipse.core.resources.ResourcesPlugin;
import org.eclipse.core.runtime.Adapters;
import org.eclipse.core.runtime.IPath;
import org.eclipse.core.runtime.IProgressMonitor;
import org.eclipse.core.runtime.IStatus;
import org.eclipse.core.runtime.OperationCanceledException;
import org.eclipse.core.runtime.Status;
import org.eclipse.core.runtime.jobs.Job;
import org.eclipse.jdt.core.IJavaProject;
import org.eclipse.jdt.core.JavaCore;
import org.eclipse.jface.dialogs.MessageDialog;
import org.eclipse.jface.viewers.ISelection;
import org.eclipse.jface.viewers.IStructuredSelection;
import org.eclipse.swt.SWT;
import org.eclipse.swt.widgets.Display;
import org.eclipse.swt.widgets.FileDialog;
import org.eclipse.swt.widgets.Shell;
import org.eclipse.ui.handlers.HandlerUtil;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

/**
 * Project &gt; Export Event Map...: maps the selected Java projects (all open Java projects when
 * none is selected) in a background job and writes the event map JSON.
 */
public class ExportEventMapHandler extends AbstractHandler {

    private static final String PLUGIN_ID = "com.eventmapper.eclipse";

    @Override
    public Object execute(ExecutionEvent event) {
        Shell shell = HandlerUtil.getActiveShell(event);
        List<IJavaProject> projects = projects(HandlerUtil.getCurrentSelection(event));
        if (projects.isEmpty()) {
            MessageDialog.openInformation(shell, "Event Mapper", "There is no open Java project to map.");
            return null;
        }
        IPath root = commonRoot(projects);
        String name = projects.size() == 1 ? projects.get(0).getElementName() : root.lastSegment();

        FileDialog dialog = new FileDialog(shell, SWT.SAVE);
        dialog.setText("Export Event Map");
        dialog.setFilterExtensions(new String[]{"*.json"});
        dialog.setFilterPath(root.toOSString());
        dialog.setFileName((name == null ? "event-map" : name) + ".json");
        dialog.setOverwrite(true);
        String target = dialog.open();
        if (target == null) {
            return null;
        }
        Path out = Path.of(target);

        Job job = new Job("Building event map") {
            @Override
            protected IStatus run(IProgressMonitor monitor) {
                monitor.beginTask("Building event map", IProgressMonitor.UNKNOWN);
                try {
                    Graph graph = new EventMapper(MapperConfig.defaults()).analyse(new JdtCodeModel(projects, root, monitor));
                    Files.writeString(out, GraphJsonWriter.write(graph), StandardCharsets.UTF_8);
                    String summary = summary(graph, out);
                    Display.getDefault().asyncExec(() -> MessageDialog.openInformation(shell, "Event Mapper", summary));
                    return Status.OK_STATUS;
                } catch (OperationCanceledException e) {
                    return Status.CANCEL_STATUS;
                } catch (IOException | RuntimeException e) {
                    return new Status(IStatus.ERROR, PLUGIN_ID, "Event map failed: " + e.getMessage(), e);
                } finally {
                    monitor.done();
                }
            }
        };
        job.setUser(true); // shows the progress dialog, which can be sent to the background
        job.schedule();
        return null;
    }

    /** The Java projects in the selection, or every open Java project when none is selected. */
    private static List<IJavaProject> projects(ISelection selection) {
        List<IJavaProject> out = new ArrayList<>();
        if (selection instanceof IStructuredSelection s) {
            for (Object o : s.toList()) {
                IProject p = Adapters.adapt(o, IProject.class);
                if (p != null && javaProject(p) != null && !out.contains(javaProject(p))) {
                    out.add(javaProject(p));
                }
            }
        }
        if (out.isEmpty()) {
            for (IProject p : ResourcesPlugin.getWorkspace().getRoot().getProjects()) {
                IJavaProject jp = javaProject(p);
                if (jp != null) {
                    out.add(jp);
                }
            }
        }
        return out;
    }

    private static IJavaProject javaProject(IProject p) {
        try {
            return p.isOpen() && p.hasNature(JavaCore.NATURE_ID) ? JavaCore.create(p) : null;
        } catch (Exception e) {
            return null;
        }
    }

    /** The deepest folder holding every project (the project itself when there is one). */
    private static IPath commonRoot(List<IJavaProject> projects) {
        IPath root = null;
        for (IJavaProject p : projects) {
            IPath loc = p.getProject().getLocation();
            if (loc == null) {
                continue;
            }
            if (root == null) {
                root = loc;
            } else {
                int n = root.matchingFirstSegments(loc);
                root = root.uptoSegment(n);
            }
        }
        // projects with nothing in common (other drives...): fall back to the workspace folder
        return root == null || root.segmentCount() == 0 ? ResourcesPlugin.getWorkspace().getRoot().getLocation() : root;
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
