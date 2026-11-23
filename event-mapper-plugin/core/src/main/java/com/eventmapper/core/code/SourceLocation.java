package com.eventmapper.core.code;

/**
 * A place in the scanned sources.
 *
 * @param file path relative to the project root, with '/' separators
 * @param line 1-based line number
 */
public record SourceLocation(String file, int line) {
}
