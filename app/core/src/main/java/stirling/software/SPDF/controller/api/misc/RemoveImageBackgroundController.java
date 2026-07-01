package stirling.software.SPDF.controller.api.misc;

import java.io.IOException;

import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.ModelAttribute;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.multipart.MultipartFile;

import io.swagger.v3.oas.annotations.Operation;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;

import stirling.software.SPDF.model.api.misc.RemoveImageBackgroundRequest;
import stirling.software.SPDF.service.RembgService;
import stirling.software.common.annotations.api.MiscApi;

@MiscApi
@Slf4j
@RequiredArgsConstructor
public class RemoveImageBackgroundController {

    private final RembgService rembgService;

    @PostMapping(value = "/remove-image-background", consumes = MediaType.MULTIPART_FORM_DATA_VALUE)
    @Operation(
            summary = "Remove the background from an image using AI (rembg)",
            description =
                    "Removes the background of an uploaded image using the rembg AI model, "
                            + "returning a PNG with a transparent background. "
                            + "Input:IMAGE Output:IMAGE Type:SISO")
    public ResponseEntity<byte[]> removeImageBackground(
            @ModelAttribute RemoveImageBackgroundRequest request) {
        MultipartFile imageFile = request.getImageFile();

        try {
            byte[] imageBytes = imageFile.getBytes();
            byte[] resultBytes =
                    rembgService.removeBackground(imageBytes, imageFile.getOriginalFilename());

            return ResponseEntity.ok().contentType(MediaType.IMAGE_PNG).body(resultBytes);
        } catch (IOException e) {
            log.error("Failed to read uploaded image", e);
            return ResponseEntity.status(HttpStatus.BAD_REQUEST).build();
        } catch (RembgService.RembgUnavailableException e) {
            log.error("rembg background removal failed", e);
            return ResponseEntity.status(HttpStatus.BAD_GATEWAY).build();
        }
    }
}
