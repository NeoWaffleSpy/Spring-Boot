package com.eventmapper.eclipse;

import org.eclipse.core.commands.AbstractHandler;
import org.eclipse.core.commands.ExecutionEvent;
import org.eclipse.core.commands.ExecutionException;
import org.eclipse.jdt.core.IJavaProject;
import org.eclipse.ui.IWorkbenchPage;
import org.eclipse.ui.PartInitException;
import org.eclipse.ui.handlers.HandlerUtil;

import java.util.List;

/**
 * Project &gt; Show Event Map: opens the Event Map view. With Java projects selected it maps them;
 * otherwise the view keeps what it maps (its toolbar chooses projects or a folder).
 */
public class ShowEventMapHandler extends AbstractHandler {

    @Override
    public Object execute(ExecutionEvent event) throws ExecutionException {
        IWorkbenchPage page = HandlerUtil.getActiveWorkbenchWindowChecked(event).getActivePage();
        try {
            EventMapView view = (EventMapView) page.showView(EventMapView.ID);
            List<IJavaProject> selected = Projects.selected(HandlerUtil.getCurrentSelection(event));
            if (!selected.isEmpty()) {
                view.setProjects(selected);
            }
        } catch (PartInitException e) {
            throw new ExecutionException("Cannot open the Event Map view", e);
        }
        return null;
    }
}
