/**********************************************************************
  Filename    : Camera Web Server
  Description : The camera images captured by the ESP32S3 are displayed on the web page.
  Auther      : www.freenove.com
  Modification: 2026/05/16
**********************************************************************/
#include "esp_camera.h"
#include <WiFi.h>
#include "board_config.h"
#include <Arduino.h>
// ===================
// Select camera model
// ===================
//#define CAMERA_MODEL_WROVER_KIT // Has PSRAM
//#define CAMERA_MODEL_ESP_EYE // Has PSRAM
#define CAMERA_MODEL_ESP32S3_EYE // Has PSRAM
//#define CAMERA_MODEL_M5STACK_PSRAM // Has PSRAM
//#define CAMERA_MODEL_M5STACK_V2_PSRAM // M5Camera version B Has PSRAM
//#define CAMERA_MODEL_M5STACK_WIDE // Has PSRAM
//#define CAMERA_MODEL_M5STACK_ESP32CAM // No PSRAM
//#define CAMERA_MODEL_M5STACK_UNITCAM // No PSRAM
//#define CAMERA_MODEL_AI_THINKER // Has PSRAM
//#define CAMERA_MODEL_TTGO_T_JOURNAL // No PSRAM
// ** Espressif Internal Boards **
//#define CAMERA_MODEL_ESP32_CAM_BOARD
//#define CAMERA_MODEL_ESP32S2_CAM_BOARD
//#define CAMERA_MODEL_ESP32S3_CAM_LCD

#include "camera_pins.h"

constexpr uint8_t CAPTURE_BUTTON_GPIO = 21;
constexpr uint32_t CAPTURE_BUTTON_DEBOUNCE_MS = 50;

volatile bool physical_capture_requested = false;
portMUX_TYPE capture_button_mux = portMUX_INITIALIZER_UNLOCKED;
bool capture_upload_in_progress();

bool consume_physical_capture_request() {
  portENTER_CRITICAL(&capture_button_mux);
  const bool requested = physical_capture_requested;
  physical_capture_requested = false;
  portEXIT_CRITICAL(&capture_button_mux);
  return requested;
}

void check_capture_button() {
  static int last_button_state = HIGH;
  static uint32_t last_press_ms = 0;
  const int button_state = digitalRead(CAPTURE_BUTTON_GPIO);

  if (last_button_state == HIGH && button_state == LOW) {
    const uint32_t now = millis();
    if (now - last_press_ms >= CAPTURE_BUTTON_DEBOUNCE_MS) {
      last_press_ms = now;
      Serial.println("Physical capture button pressed");
      if (capture_upload_in_progress()) {
        Serial.println("Capture already in progress");
      } else {
        portENTER_CRITICAL(&capture_button_mux);
        physical_capture_requested = true;
        portEXIT_CRITICAL(&capture_button_mux);
      }
    }
  }
  last_button_state = button_state;
}

// ===========================
// Enter your WiFi credentials
// ===========================
const char* ssid     = "CIK1000";
const char* password = "Wmjy2gnh@20072009";
const char* ap_ssid = "ESP32-Camera";
const char* ap_password = "camera123";
camera_config_t config;

void startCameraServer();
bool camera_init();

void setup() {
  Serial.begin(115200);
  Serial.setDebugOutput(true);
  delay(2000);
  pinMode(21, INPUT_PULLUP);
  Serial.println();
  Serial.println("ESP32 camera firmware starting...");

  if (!camera_init()) {
    Serial.println("Camera initialization failed; starting diagnostic web server");
  }

  // Use DHCP so the camera works on networks other than the originally configured subnet.
  WiFi.mode(WIFI_STA);
  WiFi.begin(ssid, password);
  WiFi.setSleep(false);

  const unsigned long wifi_timeout = 20000;
  unsigned long wifi_start = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - wifi_start < wifi_timeout) {
    delay(500);
    Serial.print(".");
  }

  if (WiFi.status() != WL_CONNECTED) {
    Serial.printf("\nWiFi connection failed, status: %d\n", WiFi.status());
    Serial.println("Starting fallback access point...");
    WiFi.disconnect(true);
    WiFi.mode(WIFI_AP);
    if (!WiFi.softAP(ap_ssid, ap_password)) {
      Serial.println("Fallback access point failed; camera server not started");
      return;
    }
    startCameraServer();
    Serial.print("Connect to WiFi network '" );
    Serial.print(ap_ssid);
    Serial.println("' with password 'camera123'");
    Serial.print("Camera Ready! Use 'http://");
    Serial.print(WiFi.softAPIP());
    Serial.println("' to connect");
    return;
  }

  Serial.println("");
  Serial.println("WiFi connected");

  startCameraServer();

  Serial.print("Camera Ready! Use 'http://");
  Serial.print(WiFi.localIP());
  Serial.println("' to connect");
}

void loop() {
  check_capture_button();
  delay(10);
}

bool camera_init() {
  config.ledc_channel = LEDC_CHANNEL_0;
  config.ledc_timer = LEDC_TIMER_0;
  config.pin_d0 = Y2_GPIO_NUM;
  config.pin_d1 = Y3_GPIO_NUM;
  config.pin_d2 = Y4_GPIO_NUM;
  config.pin_d3 = Y5_GPIO_NUM;
  config.pin_d4 = Y6_GPIO_NUM;
  config.pin_d5 = Y7_GPIO_NUM;
  config.pin_d6 = Y8_GPIO_NUM;
  config.pin_d7 = Y9_GPIO_NUM;
  config.pin_xclk = XCLK_GPIO_NUM;
  config.pin_pclk = PCLK_GPIO_NUM;
  config.pin_vsync = VSYNC_GPIO_NUM;
  config.pin_href = HREF_GPIO_NUM;
  config.pin_sccb_sda = SIOD_GPIO_NUM;
  config.pin_sccb_scl = SIOC_GPIO_NUM;
  config.pin_pwdn = PWDN_GPIO_NUM;
  config.pin_reset = RESET_GPIO_NUM;
  config.xclk_freq_hz = 10000000;
  config.frame_size = FRAMESIZE_QVGA;
  config.pixel_format = PIXFORMAT_JPEG; // for streaming
  // GRAB_LATEST + fb_count=2 lets the live /stream and the /upload_job capture
  // grab frames concurrently; fb_count=1 starves one of them and can stall
  // the camera driver badly enough to drop the streaming TCP connection.
  config.grab_mode = CAMERA_GRAB_LATEST;
  config.fb_location = CAMERA_FB_IN_PSRAM;
  config.jpeg_quality = 10;
  config.fb_count = 2;
  
  // camera init
  esp_err_t err = esp_camera_init(&config);
  if (err != ESP_OK) {
    if (err == ESP_ERR_NOT_SUPPORTED) {
      // Some sensors cannot produce JPEG directly. Clean up before retrying
      // with a raw format that the HTTP handlers can convert to JPEG.
      esp_camera_deinit();
      config.pixel_format = PIXFORMAT_RGB565;
      err = esp_camera_init(&config);
      if (err != ESP_OK) {
        Serial.printf("Camera init failed with error 0x%x\n", err);
        return false;
      }
    } else {
      Serial.printf("Camera init failed with error 0x%x\n", err);
      return false;
    }
  }

  sensor_t * s = esp_camera_sensor_get();
  if (s == nullptr) {
    Serial.println("Camera sensor not found");
    return false;
  }
  // drop down frame size for higher initial frame rate
  uint16_t pid = s->id.PID;
  if(pid == OV2640_PID){
    s->set_hmirror(s, 1);
    s->set_vflip(s, 1);     
  }
  else if(pid == OV3660_PID){
    s->set_hmirror(s, 1);
    s->set_vflip(s, 0);     
  }
  else if(pid == GC2145_PID){
    s->set_hmirror(s, 0);
    delay(500);
    s->set_vflip(s, 0);      
  }
  else if(pid == GC0308_PID){
    s->set_hmirror(s, 0);
    delay(500);
    s->set_vflip(s, 0);     
  }
  else{
    s->set_hmirror(s, 1);
    s->set_vflip(s, 0);       
  }
  s->set_brightness(s, 1);  // Slightly increase brightness
  s->set_saturation(s, 0);  // Reduce saturation
  s->set_ae_level(s, -3);   // Set exposure compensation level
  return true;
}
