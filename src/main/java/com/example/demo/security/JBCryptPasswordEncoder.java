package com.example.demo.security;

import org.mindrot.jbcrypt.BCrypt;
import org.springframework.security.crypto.password.PasswordEncoder;

/** Spring {@link PasswordEncoder} backed by jBCrypt, so stored hashes stay in the standard $2a$ format. */
public class JBCryptPasswordEncoder implements PasswordEncoder {

    private final int logRounds;

    public JBCryptPasswordEncoder(int logRounds) {
        this.logRounds = logRounds;
    }

    @Override
    public String encode(CharSequence rawPassword) {
        return BCrypt.hashpw(rawPassword.toString(), BCrypt.gensalt(logRounds));
    }

    @Override
    public boolean matches(CharSequence rawPassword, String encodedPassword) {
        if (rawPassword == null || encodedPassword == null || !encodedPassword.startsWith("$2")) {
            return false;
        }
        try {
            return BCrypt.checkpw(rawPassword.toString(), encodedPassword);
        } catch (IllegalArgumentException e) {
            return false; // malformed hash
        }
    }
}
