package com.example.demo.web;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.example.demo.api.model.Credential;
import com.example.demo.config.JacksonConfig;
import com.example.demo.config.SecurityConfig;
import com.example.demo.security.JwtService;
import com.example.demo.security.TokenDenylist;
import com.example.demo.service.AuthService;
import com.example.demo.service.UserService;
import com.example.demo.service.exception.AuthenticationFailedException;
import com.example.demo.service.exception.NotFoundException;
import io.jsonwebtoken.Claims;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.context.annotation.Import;
import org.springframework.http.MediaType;
import org.springframework.test.context.TestPropertySource;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;

/** Controllers + security filter chain, with services mocked (no database needed). */
@WebMvcTest(controllers = {UserController.class, CredentialController.class})
@Import({SecurityConfig.class, JacksonConfig.class, JwtService.class, TokenDenylist.class, ApiExceptionHandler.class})
@TestPropertySource(properties = "authority.jwt.secret=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")
class ControllerSecurityTest {

    @Autowired
    private MockMvc mvc;

    @Autowired
    private JwtService jwtService;

    @Autowired
    private TokenDenylist denylist;

    @MockitoBean
    private UserService userService;

    @MockitoBean
    private AuthService authService;

    private String bearer() {
        return "Bearer " + jwtService.issue("uuid-1", "john.doe", List.of("ADMINISTRATOR"));
    }

    @Test
    void usersRequireAToken() throws Exception {
        mvc.perform(get("/api/v1/users")).andExpect(status().isUnauthorized());
    }

    @Test
    void usersAreListedWithAValidToken() throws Exception {
        Credential john = new Credential().uuid("uuid-1").username("john.doe");
        when(userService.findAll()).thenReturn(List.of(john));

        mvc.perform(get("/api/v1/users").header("Authorization", bearer()))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.status").value(200))
                .andExpect(jsonPath("$.data[0].username").value("john.doe"))
                .andExpect(jsonPath("$.data[0].password").doesNotExist());
    }

    @Test
    void unknownUserGives404Envelope() throws Exception {
        when(userService.findByUuid("missing")).thenThrow(new NotFoundException("User not found: missing"));

        mvc.perform(get("/api/v1/users/missing").header("Authorization", bearer()))
                .andExpect(status().isNotFound())
                .andExpect(jsonPath("$.status").value(404))
                .andExpect(jsonPath("$.message").value("User not found: missing"));
    }

    @Test
    void createUserValidatesRequiredFields() throws Exception {
        mvc.perform(post("/api/v1/users").header("Authorization", bearer())
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"username\":\"jane\"}"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.status").value(400));
    }

    @Test
    void createUserReturns201() throws Exception {
        when(userService.create(any())).thenReturn(new Credential().uuid("uuid-2").username("jane"));

        mvc.perform(post("/api/v1/users").header("Authorization", bearer())
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"username\":\"jane\",\"password\":\"pw\"}"))
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.data.uuid").value("uuid-2"));
    }

    @Test
    void loginIsPublicAndReturnsToken() throws Exception {
        when(authService.login(eq("john.doe"), eq("secret"), anyString())).thenReturn("jwt-token");

        mvc.perform(post("/api/v1/sessions")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"username\":\"john.doe\",\"password\":\"secret\"}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.data").value("jwt-token"));
    }

    @Test
    void failedLoginGives401() throws Exception {
        when(authService.login(anyString(), anyString(), anyString()))
                .thenThrow(new AuthenticationFailedException("Invalid username or password"));

        mvc.perform(post("/api/v1/sessions")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"username\":\"john.doe\",\"password\":\"bad\"}"))
                .andExpect(status().isUnauthorized())
                .andExpect(jsonPath("$.message").value("Invalid username or password"));
    }

    @Test
    void tokenStopsWorkingAfterLogout() throws Exception {
        doAnswer(invocation -> {
            Claims claims = invocation.getArgument(0);
            denylist.revoke(claims.getId(), claims.getExpiration().toInstant());
            return null;
        }).when(authService).logout(any());
        String token = bearer();

        mvc.perform(post("/api/v1/sessions/logout").header("Authorization", token))
                .andExpect(status().isOk());
        mvc.perform(get("/api/v1/users").header("Authorization", token))
                .andExpect(status().isUnauthorized());
    }

    @Test
    void logoutRequiresAToken() throws Exception {
        mvc.perform(post("/api/v1/sessions/logout")).andExpect(status().isUnauthorized());
    }
}
