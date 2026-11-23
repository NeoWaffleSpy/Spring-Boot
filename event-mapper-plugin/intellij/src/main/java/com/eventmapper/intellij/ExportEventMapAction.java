package com.eventmapper.intellij;

import com.eventmapper.core.EventMapper;
import com.eventmapper.core.MapperConfig;
import com.eventmapper.core.json.GraphJsonWriter;
import com.eventmapper.core.model.Graph;
import com.eventmapper.core.model.Node;
import com.intellij.openapi.actionSystem.AnAction;
import com.intellij.openapi.actionSystem.AnActionEvent;
import com.intellij.openapi.application.ReadAction;
import com.intellij.openapi.fileChooser.FileChooserFactory;
import com.intellij.openapi.fileChooser.FileSaverDescriptor;
import com.intellij.openapi.progress.ProgressIndicator;
import com.intellij.openapi.progress.Task;
import com.intellij.openapi.project.Project;
import com.intellij.openapi.project.ProjectUtil;
import com.intellij.openapi.ui.Messages;
import com.intellij.openapi.vfs.VirtualFile;
import com.intellij.openapi.vfs.VirtualFileWrapper;
import org.jetbrains.annotations.NotNull;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Map;
import java.util.TreeMap;

/**
 * Tools | Export Event Map: asks where to save, analyses the project in the background
 * (waiting for indexing to finish if needed) and writes the event map JSON.
 */
public class ExportEventMapAction extends AnAction {

    @Override
    public void update(@NotNull AnActionEvent e) {
        e.getPresentation().setEnabledAndVisible(e.getProject() != null);
    }

    @Override
    public void actionPerformed(@NotNull AnActionEvent e) {
        Project project = e.getProject();
        VirtualFile dir = project == null ? null : ProjectUtil.guessProjectDir(project);
        if (dir == null) {
            return;
        }
        FileSaverDescriptor descriptor = new FileSaverDescriptor("Export Event Map", "Where to save the event map", "json");
        VirtualFileWrapper target = FileChooserFactory.getInstance().createSaveFileDialog(descriptor, project)
                .save(dir, project.getName() + ".json");
        if (target == null) {
            return;
        }
        Path out = target.getFile().toPath();
        String root = dir.getPath();

        new Task.Backgroundable(project, "Building event map", true) {
            private String summary;

            @Override
            public void run(@NotNull ProgressIndicator indicator) {
                indicator.setIndeterminate(true);
                // non-blocking read: restarted if the user edits meanwhile, waits for indexing
                Graph graph = ReadAction.nonBlocking(() -> new EventMapper(MapperConfig.defaults())
                                .analyse(new PsiCodeModel(project, root, indicator)))
                        .inSmartMode(project)
                        .wrapProgress(indicator)
                        .executeSynchronously();
                try {
                    Files.writeString(out, GraphJsonWriter.write(graph), StandardCharsets.UTF_8);
                } catch (IOException ex) {
                    throw new UncheckedIOException(ex);
                }
                summary = summary(graph, out);
            }

            @Override
            public void onSuccess() {
                Messages.showInfoMessage(project, summary, "Event Mapper");
            }
        }.queue();
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
