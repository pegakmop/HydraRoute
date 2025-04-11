package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"io/ioutil"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"
	"embed"
)

const (
	aghServicePath = "/opt/etc/init.d/S99adguardhome"
	filePath      = "/opt/etc/AdGuardHome/domain.conf"
	loginFile     = "/opt/etc/HydraRoute/login.scrt"
	port          = 2000
)

//go:embed public/*
var embeddedFiles embed.FS

var (
	br0IP       = getBr0IP()
	serviceLock sync.Mutex
)

func main() {
	if br0IP == "" {
		os.Exit(1)
	}

	ensureAdGuardRunning()

	mux := http.NewServeMux()
	
	mux.HandleFunc("/login", loggingMiddleware(loginHandler))
	mux.HandleFunc("/logout", loggingMiddleware(logoutHandler))
	mux.HandleFunc("/change-password", loggingMiddleware(authMiddleware(changePasswordHandler)))
	mux.HandleFunc("/", loggingMiddleware(authMiddleware(indexHandler)))
	mux.HandleFunc("/load-services", loggingMiddleware(authMiddleware(loadServicesHandler)))
	mux.HandleFunc("/config", loggingMiddleware(authMiddleware(configHandler)))
	mux.HandleFunc("/save", loggingMiddleware(authMiddleware(saveHandler)))
	mux.HandleFunc("/interfaces", loggingMiddleware(authMiddleware(interfacesHandler)))
	mux.HandleFunc("/br0ip", loggingMiddleware(authMiddleware(br0IPHandler)))
	mux.HandleFunc("/agh-status", loggingMiddleware(authMiddleware(aghStatusHandler)))
	mux.HandleFunc("/agh-restart", loggingMiddleware(authMiddleware(aghRestartHandler)))
	mux.HandleFunc("/proxy-fetch", loggingMiddleware(proxyFetchHandler))

	contentFS, err := fs.Sub(embeddedFiles, "public")
	if err != nil {
		os.Exit(1)
	}
	mux.Handle("/static/", http.StripPrefix("/static/", http.FileServer(http.FS(contentFS))))

	fmt.Printf("Сервер запущен на http://%s:%d\n", br0IP, port)
	http.ListenAndServe(fmt.Sprintf("%s:%d", br0IP, port), mux)
}

func loggingMiddleware(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		next(w, r)
	}
}

func authMiddleware(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/login" || isAuthenticated(r) {
			next(w, r)
		} else {
			http.Redirect(w, r, "/login", http.StatusFound)
		}
	}
}

func setAuth(w http.ResponseWriter) {
	http.SetCookie(w, &http.Cookie{
		Name:     "authenticated",
		Value:    "1",
		Path:     "/",
		MaxAge:   86400 * 7,
		HttpOnly: true,
	})
}

func clearAuth(w http.ResponseWriter) {
	http.SetCookie(w, &http.Cookie{
		Name:     "authenticated",
		Value:    "",
		Path:     "/",
		MaxAge:   -1,
		HttpOnly: true,
	})
}

func isAuthenticated(r *http.Request) bool {
	cookie, err := r.Cookie("authenticated")
	return err == nil && cookie.Value == "1"
}

func loginHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodGet {
		data, err := embeddedFiles.ReadFile("public/login.html")
		if err != nil {
			http.Error(w, "Login page not found", http.StatusInternalServerError)
			return
		}
		w.Write(data)
		return
	}

	if err := r.ParseForm(); err != nil {
		http.Error(w, "Invalid form data", http.StatusBadRequest)
		return
	}

	passwordKey := r.FormValue("password_key")
	if passwordKey == "" {
		http.Error(w, "Password is required", http.StatusBadRequest)
		return
	}

	encryptedPassword, err := ioutil.ReadFile(loginFile)
	if err != nil {
		http.Error(w, "Error reading password file", http.StatusInternalServerError)
		return
	}

	decodedPassword, err := decodeBase64(string(encryptedPassword))
	if err != nil {
		http.Error(w, "Error decoding password", http.StatusInternalServerError)
		return
	}

	if passwordKey != decodedPassword {
		http.Error(w, "Invalid password", http.StatusUnauthorized)
		return
	}

	setAuth(w)
	http.Redirect(w, r, "/", http.StatusFound)
}

func logoutHandler(w http.ResponseWriter, r *http.Request) {
	clearAuth(w)
	http.Redirect(w, r, "/login", http.StatusFound)
}

func changePasswordHandler(w http.ResponseWriter, r *http.Request) {
	var data struct {
		CurrentPassword string `json:"currentPassword"`
		NewPassword     string `json:"newPassword"`
	}

	if err := json.NewDecoder(r.Body).Decode(&data); err != nil {
		http.Error(w, "Invalid request payload", http.StatusBadRequest)
		return
	}

	encryptedPassword, err := ioutil.ReadFile(loginFile)
	if err != nil {
		http.Error(w, "Error reading password file", http.StatusInternalServerError)
		return
	}

	decodedPassword, err := decodeBase64(string(encryptedPassword))
	if err != nil {
		http.Error(w, "Error decoding password", http.StatusInternalServerError)
		return
	}

	if data.CurrentPassword != decodedPassword {
		http.Error(w, "Invalid current password", http.StatusUnauthorized)
		return
	}

	encodedNewPassword := base64.StdEncoding.EncodeToString([]byte(data.NewPassword))
	if err := ioutil.WriteFile(loginFile, []byte(encodedNewPassword), 0644); err != nil {
		http.Error(w, "Error writing new password to file", http.StatusInternalServerError)
		return
	}

	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]bool{"success": true})
}

func indexHandler(w http.ResponseWriter, r *http.Request) {
	data, err := embeddedFiles.ReadFile("public/index.html")
	if err != nil {
		http.Error(w, "Index page not found", http.StatusInternalServerError)
		return
	}
	w.Write(data)
}

func loadServicesHandler(w http.ResponseWriter, r *http.Request) {
	url := "https://github.com/Ground-Zerro/DomainMapper/raw/refs/heads/main/platformdb"
	var resp *http.Response
	var err error

	client := http.Client{
		Timeout: 3 * time.Second,
	}

	for i := 0; i < 3; i++ {
		resp, err = client.Get(url)
		if err == nil && resp.StatusCode == http.StatusOK {
			break
		}
		if resp != nil {
			resp.Body.Close()
		}
	}

	if err != nil || resp == nil || resp.StatusCode != http.StatusOK {
		http.Error(w, "Не удалось получить список сервисов с GitHub", http.StatusGatewayTimeout)
		return
	}
	defer resp.Body.Close()

	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		http.Error(w, "Ошибка чтения данных", http.StatusInternalServerError)
		return
	}

	lines := strings.Split(string(body), "\n")
	var services []map[string]string
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, ": ", 2)
		if len(parts) == 2 {
			name := strings.TrimSpace(parts[0])
			url := strings.TrimSpace(parts[1])
			services = append(services, map[string]string{"name": name, "url": url})
		}
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(services)
}

func getBr0IP() string {
	ifaces, err := net.Interfaces()
	if err != nil {
		return ""
	}
	for _, iface := range ifaces {
		if iface.Name == "br0" {
			addrs, err := iface.Addrs()
			if err != nil {
				return ""
			}
			for _, addr := range addrs {
				if ipnet, ok := addr.(*net.IPNet); ok && !ipnet.IP.IsLoopback() && ipnet.IP.To4() != nil {
					return ipnet.IP.String()
				}
			}
		}
	}
	return ""
}

func ensureAdGuardRunning() {
	cmd := exec.Command(aghServicePath, "status")
	output, err := cmd.CombinedOutput()
	if err != nil || !strings.Contains(string(output), "alive") {
		// fmt.Println("AdGuardHome не запущен. Попытка запуска...")
		if startErr := exec.Command(aghServicePath, "start").Run(); startErr != nil {
			// fmt.Printf("Не удалось запустить AdGuardHome: %v\n", startErr)
		} else {
			// fmt.Println("AdGuardHome успешно запущен.")
		}
	} else {
		// fmt.Println("AdGuardHome уже запущен.")
	}
}

func decodeBase64(encoded string) (string, error) {
	decoded, err := base64.StdEncoding.DecodeString(strings.TrimSpace(encoded))
	if err != nil {
		return "", err
	}
	return string(decoded), nil
}

func br0IPHandler(w http.ResponseWriter, r *http.Request) {
	json.NewEncoder(w).Encode(map[string]string{"ip": br0IP})
}

func aghStatusHandler(w http.ResponseWriter, r *http.Request) {
	cmd := exec.Command("/opt/etc/init.d/S99adguardhome", "status")
	output, err := cmd.CombinedOutput()
	if err != nil || !strings.Contains(string(output), "alive") {
		http.Error(w, "Остановлен", http.StatusInternalServerError)
		return
	}
	w.Write([]byte("Запущен и работает"))
}

func aghRestartHandler(w http.ResponseWriter, r *http.Request) {
	exec.Command(aghServicePath, "stop").Run()
	for _, ipset := range []string{"hr1", "hr2", "hr3"} {
		exec.Command("ipset", "flush", ipset).Run()
	}
	err := exec.Command(aghServicePath, "start").Run()
	if err != nil {
		http.Error(w, "Ошибка перезапуска AdGuardHome", http.StatusInternalServerError)
		return
	}
	w.Write([]byte("AdGuardHome перезапущен"))
}

func configHandler(w http.ResponseWriter, r *http.Request) {
	data := parseConfig()
	json.NewEncoder(w).Encode(data)
}

func parseConfig() map[string][]map[string]interface{} {
	content, err := ioutil.ReadFile(filePath)
	if err != nil {
		return nil
	}
	lines := strings.Split(string(content), "\n")
	result := map[string][]map[string]interface{}{
		"hr1": {}, "hr2": {}, "hr3": {},
	}
	desc := ""

	for _, line := range lines {
		if strings.HasPrefix(line, "##") {
			desc = strings.TrimSpace(line[2:])
			continue
		}
		active := true
		if strings.HasPrefix(line, "#") {
			active = false
			line = line[1:]
		}
		if idx := strings.LastIndex(line, "/"); idx != -1 {
			domains := strings.TrimSpace(line[:idx])
			ipset := line[idx+1:]
			if _, ok := result[ipset]; ok {
				result[ipset] = append(result[ipset], map[string]interface{}{
					"domains":     domains,
					"active":      active,
					"description": desc,
				})
				desc = ""
			}
		}
	}
	return result
}

func saveHandler(w http.ResponseWriter, r *http.Request) {
	var data map[string][]map[string]interface{}
	if err := json.NewDecoder(r.Body).Decode(&data); err != nil {
		http.Error(w, "Ошибка декодирования", http.StatusBadRequest)
		return
	}

	var lines []string
	for ipset, entries := range data {
		for _, e := range entries {
			if d, ok := e["description"].(string); ok && strings.TrimSpace(d) != "" {
				lines = append(lines, "##"+d)
			}
			line := e["domains"].(string)
			if !e["active"].(bool) {
				line = "#" + line
			}
			lines = append(lines, line+"/"+ipset)
		}
	}

	if err := ioutil.WriteFile(filePath, []byte(strings.Join(lines, "\n")), 0644); err != nil {
		http.Error(w, "Ошибка сохранения", http.StatusInternalServerError)
		return
	}

	exec.Command(aghServicePath, "stop").Run()
	for _, ipset := range []string{"hr1", "hr2", "hr3"} {
		exec.Command("ipset", "flush", ipset).Run()
	}
	exec.Command(aghServicePath, "start").Run()

	json.NewEncoder(w).Encode(map[string]bool{"success": true})
}

func interfacesHandler(w http.ResponseWriter, r *http.Request) {
	policyNames := []string{"HydraRoute1st", "HydraRoute2nd", "HydraRoute3rd"}
	polOut, err := exec.Command("curl", "-kfsS", "localhost:79/rci/show/ip/policy/").Output()
	if err != nil {
		http.Error(w, "Ошибка curl", http.StatusInternalServerError)
		return
	}
	var policies map[string]interface{}
	json.Unmarshal(polOut, &policies)

	ifOut, err := exec.Command("curl", "-kfsS", "localhost:79/rci/show/interface/").Output()
	if err != nil {
		http.Error(w, "Ошибка curl интерфейса", http.StatusInternalServerError)
		return
	}
	var ifaceMap map[string]interface{}
	json.Unmarshal(ifOut, &ifaceMap)

	var ifaceList []map[string]interface{}
	for _, v := range ifaceMap {
		ifaceList = append(ifaceList, v.(map[string]interface{}))
	}

	getDesc := func(id string) string {
		for _, iface := range ifaceList {
			if iface["id"] == id {
				return iface["description"].(string)
			}
		}
		return "Null"
	}

	var result []string
	for _, pname := range policyNames {
		entry := policies[pname].(map[string]interface{})
		routes := entry["route4"].(map[string]interface{})["route"].([]interface{})
		ifaceID := "Null"
		for _, r := range routes {
			route := r.(map[string]interface{})
			if route["destination"] == "0.0.0.0/0" {
				ifaceID = route["interface"].(string)
				break
			}
		}
		if ifaceID == "Null" {
			result = append(result, "Null")
		} else {
			result = append(result, getDesc(ifaceID))
		}
	}

	json.NewEncoder(w).Encode(result)
}

func proxyFetchHandler(w http.ResponseWriter, r *http.Request) {
	url := r.URL.Query().Get("url")
	if url == "" {
		http.Error(w, "Missing URL", http.StatusBadRequest)
		return
	}

	resp, err := http.Get(url)
	if err != nil || resp.StatusCode != 200 {
		http.Error(w, "Failed to fetch resource", http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	w.Header().Set("Content-Type", "text/plain")
	io.Copy(w, resp.Body)
}