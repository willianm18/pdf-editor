package stirling.software.SPDF.model.api.misc;

import org.springframework.web.multipart.MultipartFile;

import io.swagger.v3.oas.annotations.media.Schema;

import lombok.Data;

@Data
public class RemoveImageBackgroundRequest {

    @Schema(
            description = "The image file to remove the background from.",
            requiredMode = Schema.RequiredMode.REQUIRED,
            format = "binary")
    private MultipartFile imageFile;
}
