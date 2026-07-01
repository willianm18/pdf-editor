package stirling.software.SPDF.service;

import java.time.Duration;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.core.io.ByteArrayResource;
import org.springframework.http.HttpEntity;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatusCode;
import org.springframework.http.MediaType;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.stereotype.Service;
import org.springframework.util.LinkedMultiValueMap;
import org.springframework.util.MultiValueMap;
import org.springframework.web.client.ResourceAccessException;
import org.springframework.web.client.RestClientResponseException;
import org.springframework.web.client.RestTemplate;

import lombok.extern.slf4j.Slf4j;

/**
 * Talks to the rembg HTTP server (started with `rembg s`) to remove the background from an image
 * using its AI model, instead of the naive white-color-key approach.
 */
@Service
@Slf4j
public class RembgService {

    private final RestTemplate restTemplate;
    private final String rembgUrl;

    public RembgService(
            @Value("${rembg.url:http://rembg:7000}") String rembgUrl,
            @Value("${rembg.connectTimeoutSeconds:5}") long connectTimeoutSeconds,
            @Value("${rembg.readTimeoutSeconds:60}") long readTimeoutSeconds) {
        this.rembgUrl = rembgUrl;
        SimpleClientHttpRequestFactory factory = new SimpleClientHttpRequestFactory();
        factory.setConnectTimeout(Duration.ofSeconds(connectTimeoutSeconds));
        factory.setReadTimeout(Duration.ofSeconds(readTimeoutSeconds));
        this.restTemplate = new RestTemplate(factory);
    }

    /**
     * Sends the image bytes to rembg's /api/remove endpoint and returns the resulting PNG bytes
     * with the background removed.
     */
    public byte[] removeBackground(byte[] imageBytes, String filename) {
        HttpHeaders headers = new HttpHeaders();
        headers.setContentType(MediaType.MULTIPART_FORM_DATA);

        MultiValueMap<String, Object> body = new LinkedMultiValueMap<>();
        body.add(
                "file",
                new ByteArrayResource(imageBytes) {
                    @Override
                    public String getFilename() {
                        return filename != null ? filename : "image";
                    }
                });

        HttpEntity<MultiValueMap<String, Object>> requestEntity = new HttpEntity<>(body, headers);

        try {
            byte[] result =
                    restTemplate.postForObject(rembgUrl + "/api/remove", requestEntity, byte[].class);
            if (result == null || result.length == 0) {
                throw new RembgUnavailableException("rembg returned an empty response");
            }
            return result;
        } catch (ResourceAccessException e) {
            log.error("Could not reach rembg service at {}", rembgUrl, e);
            throw new RembgUnavailableException("Could not reach rembg service", e);
        } catch (RestClientResponseException e) {
            HttpStatusCode status = e.getStatusCode();
            log.error("rembg service returned an error ({}): {}", status, e.getResponseBodyAsString());
            throw new RembgUnavailableException(
                    "rembg service returned an error: " + status, e);
        }
    }

    public static class RembgUnavailableException extends RuntimeException {
        public RembgUnavailableException(String message) {
            super(message);
        }

        public RembgUnavailableException(String message, Throwable cause) {
            super(message, cause);
        }
    }
}
