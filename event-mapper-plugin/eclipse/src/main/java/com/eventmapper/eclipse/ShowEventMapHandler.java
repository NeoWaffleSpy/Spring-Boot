package com.eventmapper.eclipse;

import org.eclipse.core.commands.AbstractHandler;
import org.eclipse.core.commands.ExecutionEvent;
import org.eclipse.core.commands.ExecutionException;
import org.eclipse.ui.IWorkbenchPage;
import org.eclipse.ui.PartInitException;
import org.eclipse.ui.handlers.HandlerUtil;

/** Project &gt; Show Event Map: opens the Event Map view on the selected Java projects (all if none). */
public class ShowEventMapHandler extends AbstractHandler {

    @Override
    public Object execute(ExecutionEvent event) throws ExecutionException {
        IWorkbenchPage page = HandlerUtil.getActiveWorkbenchWindowChecked(event).getActivePage();
        try {
            EventMapView view = (EventMapView) page.showView(EventMapView.ID);
            view.setProjects(Projects.selectedOrAll(HandlerUtil.getCurrentSelection(event)));
        } catch (PartInitException e) {
            throw new ExecutionException("Cannot open the Event Map view", e);
        }
        return null;
    }
}
