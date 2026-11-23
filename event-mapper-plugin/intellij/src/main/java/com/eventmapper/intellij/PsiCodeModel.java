package com.eventmapper.intellij;

import com.eventmapper.core.code.Argument;
import com.eventmapper.core.code.CallSite;
import com.eventmapper.core.code.CodeModel;
import com.eventmapper.core.code.MethodRef;
import com.eventmapper.core.code.SourceLocation;
import com.intellij.ide.highlighter.JavaFileType;
import com.intellij.openapi.editor.Document;
import com.intellij.openapi.progress.ProgressIndicator;
import com.intellij.openapi.project.Project;
import com.intellij.openapi.util.text.StringUtil;
import com.intellij.openapi.vfs.VirtualFile;
import com.intellij.psi.JavaPsiFacade;
import com.intellij.psi.PsiClass;
import com.intellij.psi.PsiDocumentManager;
import com.intellij.psi.PsiElement;
import com.intellij.psi.PsiExpression;
import com.intellij.psi.PsiFile;
import com.intellij.psi.PsiIdentifier;
import com.intellij.psi.PsiLambdaExpression;
import com.intellij.psi.PsiLiteralExpression;
import com.intellij.psi.PsiMethod;
import com.intellij.psi.PsiMethodCallExpression;
import com.intellij.psi.PsiMethodReferenceExpression;
import com.intellij.psi.PsiReferenceExpression;
import com.intellij.psi.PsiType;
import com.intellij.psi.search.GlobalSearchScope;
import com.intellij.psi.search.PsiSearchHelper;
import com.intellij.psi.search.UsageSearchContext;
import com.intellij.psi.util.PsiTreeUtil;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * {@link CodeModel} on top of IntelliJ's PSI and indexes. Must be used inside a read action.
 *
 * <p>Calls are found through the IDE's word index (only files containing the method name are
 * looked at), then every argument is resolved by the IDE: constants are evaluated, method
 * references resolved to their declaration, receiver types computed.
 */
final class PsiCodeModel implements CodeModel {

    private final Project project;
    private final String root;
    private final ProgressIndicator indicator;
    private final GlobalSearchScope scope;

    PsiCodeModel(Project project, String root, ProgressIndicator indicator) {
        this.project = project;
        this.root = root;
        this.indicator = indicator;
        this.scope = GlobalSearchScope.getScopeRestrictedByFileTypes(GlobalSearchScope.projectScope(project), JavaFileType.INSTANCE);
    }

    @Override
    public String rootPath() {
        return root;
    }

    @Override
    public void checkCanceled() {
        indicator.checkCanceled();
    }

    @Override
    public List<CallSite> findCalls(Set<String> methodNames) {
        List<CallSite> out = new ArrayList<>();
        Set<PsiMethodCallExpression> seen = new HashSet<>();
        PsiSearchHelper search = PsiSearchHelper.getInstance(project);
        for (String name : methodNames) {
            search.processElementsWithWord((element, offset) -> {
                indicator.checkCanceled();
                // the method name of a call: identifier <- reference expression <- call
                if (element instanceof PsiIdentifier
                        && element.getParent() instanceof PsiReferenceExpression ref
                        && ref.getParent() instanceof PsiMethodCallExpression call
                        && call.getMethodExpression() == ref
                        && name.equals(ref.getReferenceName())
                        && seen.add(call)) {
                    out.add(callSite(name, call));
                }
                return true;
            }, scope, name, UsageSearchContext.IN_CODE, true);
        }
        return out;
    }

    private CallSite callSite(String name, PsiMethodCallExpression call) {
        PsiExpression q = call.getMethodExpression().getQualifierExpression();
        PsiType type = q == null ? null : q.getType();
        List<Argument> args = new ArrayList<>();
        for (PsiExpression e : call.getArgumentList().getExpressions()) {
            args.add(argument(e));
        }
        PsiMethod in = PsiTreeUtil.getParentOfType(call, PsiMethod.class);
        PsiLambdaExpression lambda = PsiTreeUtil.getParentOfType(call, PsiLambdaExpression.class, true, PsiMethod.class);
        return new CallSite(name, type == null ? null : type.getCanonicalText(), args,
                in == null ? null : method(in), lambda == null ? null : location(lambda), location(call));
    }

    private Argument argument(PsiExpression e) {
        String text = e.getText();
        if (e instanceof PsiMethodReferenceExpression ref) {
            PsiElement target = ref.resolve();
            return Argument.methodReference(text, target instanceof PsiMethod m ? method(m) : null);
        }
        if (e instanceof PsiLambdaExpression) {
            return Argument.lambda(text, location(e));
        }
        Object value = JavaPsiFacade.getInstance(project).getConstantEvaluationHelper().computeConstantExpression(e);
        if (value != null) {
            return Argument.constant(text, String.valueOf(value), e instanceof PsiLiteralExpression);
        }
        return Argument.other(text);
    }

    private MethodRef method(PsiMethod m) {
        PsiClass c = m.getContainingClass();
        String simple = c == null || c.getName() == null ? "?" : c.getName();
        String qualified = c == null ? simple : c.getQualifiedName() != null ? c.getQualifiedName() : simple;
        return new MethodRef(qualified, simple, m.getName(), location(m));
    }

    /** File (relative to the root) and line of an element, or null when it is not in a project source file. */
    private SourceLocation location(PsiElement e) {
        PsiFile file = e.getContainingFile();
        VirtualFile vf = file == null ? null : file.getVirtualFile();
        if (vf == null || !scope.contains(vf)) {
            return null;
        }
        String path = vf.getPath();
        String rel = path.startsWith(root + "/") ? path.substring(root.length() + 1) : path;
        int offset = e.getTextOffset();
        Document doc = PsiDocumentManager.getInstance(project).getDocument(file);
        int line = doc != null ? doc.getLineNumber(offset) : StringUtil.offsetToLineNumber(file.getText(), offset);
        return new SourceLocation(rel, line + 1);
    }
}
