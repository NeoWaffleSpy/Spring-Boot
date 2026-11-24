package com.eventmapper.core.code;

import java.util.List;
import java.util.Map;

/**
 * A method carrying at least one of the annotations asked for, with every annotation on it and on
 * its class (class-level ones give the URL prefix of endpoints).
 *
 * @param method           the method
 * @param annotations      annotations on the method
 * @param classAnnotations annotations on the method's class
 * @param firstParamType   simple name of the first parameter's type ({@code OrderCreated}), or {@code null}
 */
public record AnnotatedMethod(MethodRef method, List<Annotation> annotations, List<Annotation> classAnnotations,
                              String firstParamType) {

    public AnnotatedMethod {
        annotations = List.copyOf(annotations);
        classAnnotations = List.copyOf(classAnnotations);
    }

    /**
     * One annotation.
     *
     * @param name   simple name ({@code GetMapping})
     * @param values attribute name to its values; the unnamed value of {@code @A("x")} is under "value",
     *               an array attribute gives several values
     */
    public record Annotation(String name, Map<String, List<Argument>> values) {

        public Annotation {
            values = Map.copyOf(values);
        }
    }
}
