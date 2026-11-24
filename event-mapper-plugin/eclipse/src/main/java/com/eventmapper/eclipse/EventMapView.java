package com.eventmapper.eclipse;

import com.eventmapper.core.EventMapper;
import com.eventmapper.core.MapperConfig;
import com.eventmapper.core.json.GraphJsonWriter;
import com.eventmapper.core.model.Graph;
import com.eventmapper.core.page.PageRenderer;
import org.eclipse.core.resources.IResource;
import org.eclipse.core.runtime.IProgressMonitor;
import org.eclipse.core.runtime.IStatus;
import org.eclipse.core.runtime.OperationCanceledException;
import org.eclipse.core.runtime.Platform;
import org.eclipse.core.runtime.Status;
import org.eclipse.core.runtime.jobs.Job;
import org.eclipse.jdt.core.ElementChangedEvent;
import org.eclipse.jdt.core.ICompilationUnit;
import org.eclipse.jdt.core.IElementChangedListener;
import org.eclipse.jdt.core.IJavaElement;
import org.eclipse.jdt.core.IJavaElementDelta;
import org.eclipse.jdt.core.IJavaProject;
import org.eclipse.jdt.core.JavaCore;
import org.eclipse.jdt.ui.JavaUI;
import org.eclipse.jface.action.Action;
import org.eclipse.jface.action.IAction;
import org.eclipse.jface.action.IToolBarManager;
import org.eclipse.jface.text.ITextSelection;
import org.eclipse.jface.viewers.ISelection;
import org.eclipse.swt.SWT;
import org.eclipse.swt.SWTError;
import org.eclipse.swt.SWTException;
import org.eclipse.swt.browser.Browser;
import org.eclipse.swt.browser.BrowserFunction;
import org.eclipse.swt.layout.FillLayout;
import org.eclipse.swt.widgets.Composite;
import org.eclipse.swt.widgets.Display;
import org.eclipse.swt.widgets.FileDialog;
import org.eclipse.swt.widgets.Label;
import org.eclipse.ui.IEditorPart;
import org.eclipse.ui.ISelectionListener;
import org.eclipse.ui.ISharedImages;
import org.eclipse.ui.IWorkbenchPart;
import org.eclipse.ui.PlatformUI;
import org.eclipse.ui.part.ViewPart;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * The Event Map view: the event map page (core's {@code PageRenderer}), live. It maps the chosen Java
 * projects (all open ones by default), refreshes on its own a moment after Java files are saved
 * (re-parsing only what changed), opens sources when a location is clicked (or a graph node is
 * double-clicked), and can follow the editor: the method under the cursor is shown in the map.
 */
public class EventMapView extends ViewPart {

    public static final String ID = "com.eventmapper.eclipse.view";
    private static final String PLUGIN_ID = "com.eventmapper.eclipse";
    /** wait after a save before refreshing, so a burst of saves gives one refresh */
    private static final long REFRESH_DELAY_MS = 1500;

    private Browser browser;
    private Path pageFile;
    private boolean pageLoaded;
    private volatile JdtCodeModel model;
    private volatile String lastJson;
    private volatile boolean fullRefresh = true;
    private final Set<IResource> changed = new HashSet<>();
    private boolean linkWithEditor;
    private String lastRevealed;
    private Job refreshJob;
    private IElementChangedListener javaListener;
    private ISelectionListener editorListener;

    @Override
    public void createPartControl(Composite parent) {
        parent.setLayout(new FillLayout());
        try {
            browser = new Browser(parent, SWT.EDGE);
        } catch (SWTError e) {
            Label l = new Label(parent, SWT.WRAP);
            l.setText("The Event Map view needs the Microsoft Edge WebView2 runtime, which could not be started:\n"
                    + e.getMessage() + "\n\nUse Project > Export Event Map... to write the map to a file instead.");
            log(IStatus.WARNING, "Event Map view: Edge browser not available", e);
            return;
        }
        browser.setText(message("Building the event map…"));
        new BrowserFunction(browser, "evmapOpen") {
            @Override
            public Object function(Object[] args) {
                if (args.length >= 2 && args[0] instanceof String path && args[1] instanceof Number line) {
                    // after the call returns: opening an editor from inside a browser callback is not safe
                    Display.getCurrent().asyncExec(() -> SourceOpener.open(getSite().getPage(), path, line.intValue()));
                }
                return null;
            }
        };
        try {
            pageFile = Files.createTempFile("event-map-", ".html");
        } catch (IOException e) {
            browser.setText(message("Cannot create a temporary file: " + e.getMessage()));
            return;
        }

        refreshJob = new Job("Refreshing event map") {
            @Override
            protected IStatus run(IProgressMonitor monitor) {
                return refresh(monitor);
            }
        };
        contributeActions();

        javaListener = this::javaChanged;
        JavaCore.addElementChangedListener(javaListener, ElementChangedEvent.POST_CHANGE);
        editorListener = this::editorSelectionChanged;
        getSite().getPage().addPostSelectionListener(editorListener);

        setProjects(Projects.selectedOrAll(null));
    }

    /** Maps these projects from now on. */
    public void setProjects(List<IJavaProject> projects) {
        if (browser == null || pageFile == null) {
            return;
        }
        if (projects.isEmpty()) {
            model = null;
            browser.setText(message("There is no open Java project to map."));
            pageLoaded = false;
            return;
        }
        JdtCodeModel m = new JdtCodeModel(projects, Projects.commonRoot(projects));
        model = m;
        setContentDescription(projects.size() == 1 ? projects.get(0).getElementName()
                : projects.size() + " projects under " + m.root().toOSString());
        scheduleRefresh(true);
    }

    private void contributeActions() {
        IToolBarManager bar = getViewSite().getActionBars().getToolBarManager();
        ISharedImages images = PlatformUI.getWorkbench().getSharedImages();

        Action refresh = new Action("Refresh") {
            @Override
            public void run() {
                scheduleRefresh(true);
            }
        };
        refresh.setToolTipText("Re-analyse every file (the map also refreshes by itself when Java files are saved)");
        refresh.setImageDescriptor(images.getImageDescriptor(ISharedImages.IMG_ELCL_SYNCED));

        Action link = new Action("Link with Editor", IAction.AS_CHECK_BOX) {
            @Override
            public void run() {
                linkWithEditor = isChecked();
                lastRevealed = null;
            }
        };
        link.setToolTipText("Show the method under the editor's cursor in the map");
        link.setImageDescriptor(images.getImageDescriptor(ISharedImages.IMG_TOOL_FORWARD));

        Action export = new Action("Export JSON…") {
            @Override
            public void run() {
                exportJson();
            }
        };
        export.setToolTipText("Save the current map as JSON");
        export.setImageDescriptor(images.getImageDescriptor(ISharedImages.IMG_ETOOL_SAVE_EDIT));

        bar.add(refresh);
        bar.add(link);
        bar.add(export);
    }

    // ---- refresh ----------------------------------------------------------------------------

    private void scheduleRefresh(boolean full) {
        if (refreshJob == null) {
            return;
        }
        if (full) {
            fullRefresh = true;
        }
        refreshJob.cancel();
        refreshJob.schedule(full ? 0 : REFRESH_DELAY_MS);
    }

    /** Runs in the refresh job. */
    private IStatus refresh(IProgressMonitor monitor) {
        JdtCodeModel m = model;
        if (m == null) {
            return Status.OK_STATUS;
        }
        monitor.beginTask("Building event map", IProgressMonitor.UNKNOWN);
        try {
            if (fullRefresh) {
                fullRefresh = false;
                m.clear();
                synchronized (changed) {
                    changed.clear();
                }
            } else {
                List<IResource> saved;
                synchronized (changed) {
                    saved = new ArrayList<>(changed);
                    changed.clear();
                }
                m.invalidate(saved);
            }
            m.setMonitor(monitor);
            Graph graph = new EventMapper(MapperConfig.defaults()).analyse(m);
            String json = GraphJsonWriter.write(graph);
            String title = Projects.name(m.projects(), m.root());
            lastJson = json;
            Display.getDefault().asyncExec(() -> show(m, title, json));
            return Status.OK_STATUS;
        } catch (OperationCanceledException e) {
            return Status.CANCEL_STATUS;
        } catch (Throwable e) {
            log(IStatus.ERROR, "Event map failed: " + e, e);
            Display.getDefault().asyncExec(() -> {
                if (browser != null && !browser.isDisposed()) {
                    browser.setText(message("The event map could not be built: " + e + "<br><br>Details are in the Error Log view."));
                    pageLoaded = false;
                }
            });
            return Status.OK_STATUS; // already reported
        } finally {
            monitor.done();
        }
    }

    /** On the UI thread: shows the new map, keeping the page's current view (selection, graph, scroll). */
    private void show(JdtCodeModel m, String title, String json) {
        if (browser == null || browser.isDisposed() || m != model) {
            return;
        }
        String state = null;
        if (pageLoaded) {
            try {
                Object s = browser.evaluate("return window.evmapState ? window.evmapState() : null;");
                state = s instanceof String str ? str : null;
            } catch (SWTException e) {
                // page not ready: start from a fresh view
            }
        }
        try {
            Files.writeString(pageFile, PageRenderer.renderForIde(title, json, state), StandardCharsets.UTF_8);
        } catch (IOException e) {
            log(IStatus.ERROR, "Event Map view: cannot write " + pageFile, e);
            return;
        }
        if (pageLoaded) {
            browser.refresh();
        } else {
            browser.setUrl(pageFile.toUri().toString());
            pageLoaded = true;
        }
        lastRevealed = null;
    }

    /** JDT change events: a saved, added or removed Java file of a mapped project refreshes the map. */
    private void javaChanged(ElementChangedEvent event) {
        JdtCodeModel m = model;
        if (m == null) {
            return;
        }
        boolean[] full = {false};
        List<IResource> files = new ArrayList<>();
        collect(event.getDelta(), m.projects(), files, full);
        if (full[0]) {
            scheduleRefresh(true);
        } else if (!files.isEmpty()) {
            synchronized (changed) {
                changed.addAll(files);
            }
            scheduleRefresh(false);
        }
    }

    private static void collect(IJavaElementDelta delta, List<IJavaProject> projects, List<IResource> files, boolean[] full) {
        IJavaElement e = delta.getElement();
        if (e.getJavaProject() != null && !projects.contains(e.getJavaProject())) {
            return;
        }
        int flags = delta.getFlags();
        if ((flags & (IJavaElementDelta.F_CLASSPATH_CHANGED | IJavaElementDelta.F_RESOLVED_CLASSPATH_CHANGED)) != 0) {
            full[0] = true;
        }
        if (e instanceof ICompilationUnit cu) {
            boolean saved = delta.getKind() != IJavaElementDelta.CHANGED
                    || (flags & IJavaElementDelta.F_PRIMARY_RESOURCE) != 0
                    || ((flags & IJavaElementDelta.F_CONTENT) != 0 && !cu.isWorkingCopy());
            if (saved && cu.getResource() != null) {
                files.add(cu.getResource());
            }
            return;
        }
        for (IJavaElementDelta child : delta.getAffectedChildren()) {
            collect(child, projects, files, full);
        }
    }

    // ---- link with editor ---------------------------------------------------------------------

    private void editorSelectionChanged(IWorkbenchPart part, ISelection selection) {
        if (!linkWithEditor || !pageLoaded || browser == null || browser.isDisposed()
                || !(part instanceof IEditorPart editor) || !(selection instanceof ITextSelection text)) {
            return;
        }
        if (!(JavaUI.getEditorInputJavaElement(editor.getEditorInput()) instanceof ICompilationUnit cu)) {
            return;
        }
        for (String id : JdtCodeModel.methodIdsAt(cu, text.getOffset())) {
            if (id.equals(lastRevealed)) {
                return;
            }
            try {
                Object found = browser.evaluate("return window.evmapReveal ? window.evmapReveal(" + jsString(id) + ") : false;");
                if (Boolean.TRUE.equals(found)) {
                    lastRevealed = id;
                    return;
                }
            } catch (SWTException e) {
                return;
            }
        }
    }

    private static String jsString(String s) {
        StringBuilder b = new StringBuilder("\"");
        for (char c : s.toCharArray()) {
            if (c == '"' || c == '\\') {
                b.append('\\').append(c);
            } else if (c < 0x20 || c == '<' || c == '>') {
                b.append(String.format("\\u%04x", (int) c));
            } else {
                b.append(c);
            }
        }
        return b.append('"').toString();
    }

    // ---- export -------------------------------------------------------------------------------

    private void exportJson() {
        JdtCodeModel m = model;
        String json = lastJson;
        if (m == null || json == null) {
            return;
        }
        FileDialog dialog = new FileDialog(getSite().getShell(), SWT.SAVE);
        dialog.setText("Export Event Map");
        dialog.setFilterExtensions(new String[]{"*.json"});
        dialog.setFilterPath(m.root().toOSString());
        dialog.setFileName(Projects.name(m.projects(), m.root()) + ".json");
        dialog.setOverwrite(true);
        String target = dialog.open();
        if (target == null) {
            return;
        }
        try {
            Files.writeString(Path.of(target), json, StandardCharsets.UTF_8);
        } catch (IOException e) {
            log(IStatus.ERROR, "Event Map view: cannot write " + target, e);
        }
    }

    // ---- misc ---------------------------------------------------------------------------------

    private static String message(String html) {
        return "<!DOCTYPE html><html><body style=\"font:13px system-ui,sans-serif;color:#6b6b70;padding:24px\">"
                + html + "</body></html>";
    }

    private static void log(int severity, String message, Throwable e) {
        Platform.getLog(EventMapView.class).log(new Status(severity, PLUGIN_ID, message, e));
    }

    @Override
    public void setFocus() {
        if (browser != null && !browser.isDisposed()) {
            browser.setFocus();
        }
    }

    @Override
    public void dispose() {
        if (javaListener != null) {
            JavaCore.removeElementChangedListener(javaListener);
        }
        if (editorListener != null) {
            getSite().getPage().removePostSelectionListener(editorListener);
        }
        if (refreshJob != null) {
            refreshJob.cancel();
        }
        model = null;
        if (pageFile != null) {
            try {
                Files.deleteIfExists(pageFile);
            } catch (IOException ignored) {
                // a temporary file left behind
            }
        }
        super.dispose();
    }
}
