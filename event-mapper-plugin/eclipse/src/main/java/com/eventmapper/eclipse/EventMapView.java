package com.eventmapper.eclipse;

import com.eventmapper.core.EventMapper;
import com.eventmapper.core.MapperConfig;
import com.eventmapper.core.json.GraphJsonWriter;
import com.eventmapper.core.model.Graph;
import com.eventmapper.core.page.PageRenderer;
import org.eclipse.core.resources.IResource;
import org.eclipse.core.runtime.IPath;
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
import org.eclipse.jface.dialogs.MessageDialog;
import org.eclipse.jface.viewers.ArrayContentProvider;
import org.eclipse.jface.viewers.LabelProvider;
import org.eclipse.jface.window.Window;
import org.eclipse.swt.widgets.DirectoryDialog;
import org.eclipse.ui.IMemento;
import org.eclipse.ui.IViewSite;
import org.eclipse.ui.PartInitException;
import org.eclipse.ui.dialogs.ListSelectionDialog;
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
    private static final String KEY_ROOT = "root";
    private static final String KEY_PROJECTS = "projects";

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
    /** what the view mapped when the workbench last closed */
    private String savedRoot;
    private List<String> savedProjects;

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

        // what was mapped last time (the view remembers it), else every open Java project
        List<IJavaProject> restored = savedProjects == null ? List.of() : Projects.named(savedProjects);
        if (!restored.isEmpty()) {
            boolean rootExists = savedRoot != null && new java.io.File(savedRoot).isDirectory();
            setProjects(restored, rootExists ? org.eclipse.core.runtime.Path.fromOSString(savedRoot) : null);
        } else {
            setProjects(Projects.all(), null);
        }
    }

    @Override
    public void init(IViewSite site, IMemento memento) throws PartInitException {
        super.init(site, memento);
        if (memento != null) {
            savedRoot = memento.getString(KEY_ROOT);
            String names = memento.getString(KEY_PROJECTS);
            savedProjects = names == null || names.isBlank() ? null : List.of(names.split("\n"));
        }
    }

    @Override
    public void saveState(IMemento memento) {
        JdtCodeModel m = model;
        if (m != null) {
            memento.putString(KEY_ROOT, m.root().toOSString());
            memento.putString(KEY_PROJECTS, String.join("\n", m.projects().stream().map(IJavaProject::getElementName).toList()));
        }
    }

    /** Maps these projects from now on, from the folder that holds them all. */
    public void setProjects(List<IJavaProject> projects) {
        setProjects(projects, null);
    }

    /**
     * Maps these projects from now on.
     *
     * @param root the folder the map is made from (file paths, components, file count), or null for
     *             the deepest folder holding every project
     */
    public void setProjects(List<IJavaProject> projects, IPath root) {
        if (browser == null || pageFile == null) {
            return;
        }
        if (projects.isEmpty()) {
            model = null;
            browser.setText(message("There is no open Java project to map. Import your project (File &gt; Import &gt; "
                    + "Maven &gt; Existing Maven Projects), then use the view's toolbar to choose what to map."));
            pageLoaded = false;
            setContentDescription("");
            return;
        }
        JdtCodeModel m = new JdtCodeModel(projects, root != null ? root : Projects.commonRoot(projects));
        model = m;
        setContentDescription(describe(m) + " · building…");
        scheduleRefresh(true);
    }

    private static String describe(JdtCodeModel m) {
        List<IJavaProject> ps = m.projects();
        return (ps.size() == 1 ? ps.get(0).getElementName() : ps.size() + " projects") + " under " + m.root().toOSString();
    }

    /** Toolbar: pick the projects to map from the open Java projects. */
    private void chooseProjects() {
        List<IJavaProject> all = Projects.all();
        if (all.isEmpty()) {
            MessageDialog.openInformation(getSite().getShell(), "Event Mapper", "There is no open Java project in the workspace.");
            return;
        }
        @SuppressWarnings("deprecation") // the builder replacing this constructor is not in Eclipse 2022-09
        ListSelectionDialog dialog = new ListSelectionDialog(getSite().getShell(), all, ArrayContentProvider.getInstance(),
                new LabelProvider() {
                    @Override
                    public String getText(Object o) {
                        IJavaProject p = (IJavaProject) o;
                        IPath loc = p.getProject().getLocation();
                        return p.getElementName() + (loc == null ? "" : "   —   " + loc.toOSString());
                    }
                }, "Projects to map (only Java projects are listed: import missing modules with File > Import > Maven):");
        dialog.setTitle("Event Map: Choose Projects");
        JdtCodeModel m = model;
        if (m != null) {
            dialog.setInitialSelections(m.projects().toArray());
        }
        if (dialog.open() == Window.OK) {
            List<IJavaProject> chosen = new ArrayList<>();
            for (Object o : dialog.getResult()) {
                chosen.add((IJavaProject) o);
            }
            setProjects(chosen, null);
        }
    }

    /** Toolbar: map every Java project inside a folder, from that folder. */
    private void mapFolder() {
        DirectoryDialog dialog = new DirectoryDialog(getSite().getShell());
        dialog.setText("Event Map: Map Folder");
        dialog.setMessage("Map every Java project inside this folder (e.g. the root of a multi-module app):");
        JdtCodeModel m = model;
        if (m != null) {
            dialog.setFilterPath(m.root().toOSString());
        }
        String folder = dialog.open();
        if (folder == null) {
            return;
        }
        IPath root = org.eclipse.core.runtime.Path.fromOSString(folder);
        List<IJavaProject> inside = Projects.under(root);
        if (inside.isEmpty()) {
            MessageDialog.openInformation(getSite().getShell(), "Event Mapper", "No open Java project is inside " + folder
                    + ".\n\nImport its modules first: File > Import > Maven > Existing Maven Projects, pointing at that folder.");
            return;
        }
        setProjects(inside, root);
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

        Action projects = new Action("Choose Projects…") {
            @Override
            public void run() {
                chooseProjects();
            }
        };
        projects.setToolTipText("Choose the Java projects to map");
        projects.setImageDescriptor(images.getImageDescriptor(org.eclipse.ui.ide.IDE.SharedImages.IMG_OBJ_PROJECT));

        Action folder = new Action("Map Folder…") {
            @Override
            public void run() {
                mapFolder();
            }
        };
        folder.setToolTipText("Map every Java project inside a folder, e.g. the root of a multi-module app");
        folder.setImageDescriptor(images.getImageDescriptor(ISharedImages.IMG_OBJ_FOLDER));

        bar.add(projects);
        bar.add(folder);
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
            m.resetStats();
            Graph graph = new EventMapper(MapperConfig.defaults()).analyse(m);
            String json = GraphJsonWriter.write(graph);
            String title = Projects.name(m.projects(), m.root());
            lastJson = json;
            int indexed = m.sourceFileCount();
            String status = status(m, graph, indexed);
            log(IStatus.INFO, "Event map of " + describe(m) + ": projects " + m.projects().stream().map(IJavaProject::getElementName).toList()
                    + "; " + graph.files + " Java files in the folder, " + indexed + " in the mapped projects; "
                    + graph.nodes().size() + " nodes, " + graph.edges().size() + " links; found " + m.stats(), null);
            Display.getDefault().asyncExec(() -> {
                show(m, title, json);
                if (m == model && browser != null && !browser.isDisposed()) {
                    setContentDescription(status);
                }
            });
            return Status.OK_STATUS;
        } catch (OperationCanceledException e) {
            return Status.CANCEL_STATUS;
        } catch (Throwable e) {
            Display.getDefault().asyncExec(() -> showError("The event map could not be built", e));
            return Status.OK_STATUS; // reported in the view and the Error Log
        } finally {
            monitor.done();
        }
    }

    /**
     * The line under the view's tab: what is mapped, and a warning when most Java files of the folder are
     * not in the mapped Java projects (modules not imported, or not imported as Java projects).
     */
    private static String status(JdtCodeModel m, Graph g, int indexed) {
        String s = describe(m) + " · " + indexed + " Java files indexed";
        if (g.files > 0 && indexed < g.files * 0.8) {
            s += " — but the folder has " + g.files + ": import the missing modules (File > Import > Maven), "
                    + "then use Map Folder… or Choose Projects…";
        }
        return s;
    }

    /** On the UI thread: shows the new map, keeping the page's current view (selection, graph, scroll). */
    private void show(JdtCodeModel m, String title, String json) {
        if (browser == null || browser.isDisposed() || m != model) {
            return;
        }
        try {
            showPage(title, json);
        } catch (Throwable e) { // shown in the view rather than as an event loop error
            showError("The event map could not be shown", e);
        }
    }

    private void showError(String what, Throwable e) {
        log(IStatus.ERROR, what + ": " + e, e);
        if (browser != null && !browser.isDisposed()) {
            Throwable root = e;
            while (root.getCause() != null && root.getCause() != root) {
                root = root.getCause();
            }
            browser.setText(message(escape(what) + ":<br><br><b>" + escape(String.valueOf(root)) + "</b>"
                    + "<br><br>Details are in the Error Log view (Window &gt; Show View &gt; General &gt; Error Log)."));
            pageLoaded = false;
        }
    }

    private static String escape(String s) {
        return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;");
    }

    private void showPage(String title, String json) {
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
