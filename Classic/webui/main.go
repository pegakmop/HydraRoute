package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"time"
	"embed"
)

const (
	aghServicePath = "/opt/etc/init.d/S99adguardhome"
	filePath      = "/opt/etc/AdGuardHome/domain.conf"
	loginFile     = "/opt/etc/HydraRoute/login.scrt"
	port          = 2000
	servicesURL   = "https://github.com/Ground-Zerro/DomainMapper/raw/refs/heads/main/platformdb"
	httpTimeout   = 3 * time.Second
	retryCount    = 3
)

//go:embed public/*
var embeddedFiles embed.FS

var br0IP = getBr0IP()

func main() {
	if br0IP == "" {
		fmt.Println("Не удалось получить IP адрес интерфейса br0")
		os.Exit(1)
	}

	ensureAdGuardRunning()

	mux := setupRoutes()
	
	fmt.Printf("Сервер запущен на http://%s:%d\n", br0IP, port)
	if err := http.ListenAndServe(fmt.Sprintf("%s:%d", br0IP, port), mux); err != nil {
		fmt.Printf("Ошибка запуска сервера: %v\n", err)
		os.Exit(1)
	}
}

func setupRoutes() *http.ServeMux {
	mux := http.NewServeMux()
	
	// API маршруты с аутентификацией
	authRoutes := map[string]http.HandlerFunc{
		"/":                indexHandler,
		"/change-password": changePasswordHandler,
		"/load-services":   loadServicesHandler,
		"/config":          configHandler,
		"/save":            saveHandler,
		"/interfaces":      interfacesHandler,
		"/br0ip":           br0IPHandler,
		"/agh-status":      aghStatusHandler,
		"/agh-restart":     aghRestartHandler,
	}
	
	for path, handler := range authRoutes {
		mux.HandleFunc(path, authMiddleware(handler))
	}
	
	// Публичные маршруты
	mux.HandleFunc("/login", loginHandler)
	mux.HandleFunc("/logout", logoutHandler)
	mux.HandleFunc("/proxy-fetch", proxyFetchHandler)
	
	// Статические файлы
	setupStaticRoutes(mux)
	
	return mux
}

func setupStaticRoutes(mux *http.ServeMux) {
	contentFS, err := fs.Sub(embeddedFiles, "public")
	if err != nil {
		fmt.Printf("Ошибка настройки статических файлов: %v\n", err)
		os.Exit(1)
	}
	
	fileServer := http.FileServer(http.FS(contentFS))
	staticHandler := createStaticHandler(fileServer)
	
	mux.HandleFunc("/style.css", staticHandler)
	mux.HandleFunc("/script.js", staticHandler)
	mux.Handle("/assets/", fileServer)
}

func createStaticHandler(fileServer http.Handler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path
		staticExtensions := []string{".css", ".js", ".svg", ".woff2"}
		
		isStatic := strings.HasPrefix(path, "/assets/")
		for _, ext := range staticExtensions {
			if strings.HasSuffix(path, ext) {
				isStatic = true
				break
			}
		}
		
		if isStatic {
			fileServer.ServeHTTP(w, r)
		} else {
			http.NotFound(w, r)
		}
	}
}

func authMiddleware(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if isAuthenticated(r) {
			next(w, r)
		} else {
			http.Redirect(w, r, "/login", http.StatusFound)
		}
	}
}

func isAuthenticated(r *http.Request) bool {
	cookie, err := r.Cookie("authenticated")
	return err == nil && cookie.Value == "1"
}

func setAuthCookie(w http.ResponseWriter) {
	http.SetCookie(w, &http.Cookie{
		Name:     "authenticated",
		Value:    "1",
		Path:     "/",
		MaxAge:   86400 * 7,
		HttpOnly: true,
	})
}

func clearAuthCookie(w http.ResponseWriter) {
	http.SetCookie(w, &http.Cookie{
		Name:     "authenticated",
		Value:    "",
		Path:     "/",
		MaxAge:   -1,
		HttpOnly: true,
	})
}

func loginHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodGet {
		serveEmbeddedFile(w, "public/login.html", "Login page not found")
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

	if !validatePassword(passwordKey) {
		http.Error(w, "Invalid password", http.StatusUnauthorized)
		return
	}

	setAuthCookie(w)
	http.Redirect(w, r, "/", http.StatusFound)
}

func validatePassword(password string) bool {
	encryptedPassword, err := os.ReadFile(loginFile)
	if err != nil {
		return false
	}

	decodedPassword, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(encryptedPassword)))
	if err != nil {
		return false
	}

	return password == string(decodedPassword)
}

func logoutHandler(w http.ResponseWriter, r *http.Request) {
	clearAuthCookie(w)
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

	if !validatePassword(data.CurrentPassword) {
		http.Error(w, "Invalid current password", http.StatusUnauthorized)
		return
	}

	encodedNewPassword := base64.StdEncoding.EncodeToString([]byte(data.NewPassword))
	if err := os.WriteFile(loginFile, []byte(encodedNewPassword), 0644); err != nil {
		http.Error(w, "Error writing new password to file", http.StatusInternalServerError)
		return
	}

	respondJSON(w, map[string]bool{"success": true})
}

func indexHandler(w http.ResponseWriter, r *http.Request) {
	serveEmbeddedFile(w, "public/index.html", "Index page not found")
}

func serveEmbeddedFile(w http.ResponseWriter, path, errorMsg string) {
	data, err := embeddedFiles.ReadFile(path)
	if err != nil {
		http.Error(w, errorMsg, http.StatusInternalServerError)
		return
	}
	w.Write(data)
}

func loadServicesHandler(w http.ResponseWriter, r *http.Request) {
	client := &http.Client{Timeout: httpTimeout}
	
	var resp *http.Response
	var err error

	for i := 0; i < retryCount; i++ {
		resp, err = client.Get(servicesURL)
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

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		http.Error(w, "Ошибка чтения данных", http.StatusInternalServerError)
		return
	}

	services := parseServices(string(body))
	respondJSON(w, services)
}

func parseServices(content string) []map[string]string {
	lines := strings.Split(content, "\n")
	var services []map[string]string
	
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		
		if parts := strings.SplitN(line, ": ", 2); len(parts) == 2 {
			services = append(services, map[string]string{
				"name": strings.TrimSpace(parts[0]),
				"url":  strings.TrimSpace(parts[1]),
			})
		}
	}
	
	return services
}

func getBr0IP() string {
	ifaces, err := net.Interfaces()
	if err != nil {
		return ""
	}
	
	for _, iface := range ifaces {
		if iface.Name != "br0" {
			continue
		}
		
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		
		for _, addr := range addrs {
			if ipnet, ok := addr.(*net.IPNet); ok && !ipnet.IP.IsLoopback() && ipnet.IP.To4() != nil {
				return ipnet.IP.String()
			}
		}
	}
	return ""
}

func ensureAdGuardRunning() {
	if !isAdGuardRunning() {
		startAdGuard()
	}
}

func isAdGuardRunning() bool {
	output, err := exec.Command(aghServicePath, "status").CombinedOutput()
	return err == nil && strings.Contains(string(output), "alive")
}

func startAdGuard() {
	if err := exec.Command(aghServicePath, "start").Run(); err != nil {
		fmt.Printf("Не удалось запустить AdGuardHome: %v\n", err)
	}
}

func br0IPHandler(w http.ResponseWriter, r *http.Request) {
	respondJSON(w, map[string]string{"ip": br0IP})
}

func aghStatusHandler(w http.ResponseWriter, r *http.Request) {
	if isAdGuardRunning() {
		w.Write([]byte("Запущен и работает"))
	} else {
		http.Error(w, "Остановлен", http.StatusInternalServerError)
	}
}

func aghRestartHandler(w http.ResponseWriter, r *http.Request) {
	exec.Command(aghServicePath, "stop").Run()
	
	ipsets := []string{"hr1", "hr2", "hr3"}
	for _, ipset := range ipsets {
		exec.Command("ipset", "flush", ipset).Run()
	}
	
	if err := exec.Command(aghServicePath, "start").Run(); err != nil {
		http.Error(w, "Ошибка перезапуска AdGuardHome", http.StatusInternalServerError)
		return
	}
	
	w.Write([]byte("AdGuardHome перезапущен"))
}

func configHandler(w http.ResponseWriter, r *http.Request) {
	data := parseConfig()
	respondJSON(w, data)
}

func parseConfig() map[string][]map[string]interface{} {
	content, err := os.ReadFile(filePath)
	if err != nil {
		return map[string][]map[string]interface{}{
			"hr1": {}, "hr2": {}, "hr3": {},
		}
	}
	
	lines := strings.Split(string(content), "\n")
	result := map[string][]map[string]interface{}{
		"hr1": {}, "hr2": {}, "hr3": {},
	}
	
	var currentDesc string
	
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		
		if strings.HasPrefix(line, "##") {
			currentDesc = strings.TrimSpace(line[2:])
			continue
		}
		
		active := !strings.HasPrefix(line, "#")
		if !active {
			line = line[1:]
		}
		
		if idx := strings.LastIndex(line, "/"); idx != -1 {
			domains := strings.TrimSpace(line[:idx])
			ipset := line[idx+1:]
			
			if _, exists := result[ipset]; exists {
				result[ipset] = append(result[ipset], map[string]interface{}{
					"domains":     domains,
					"active":      active,
					"description": currentDesc,
				})
				currentDesc = ""
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

	content := buildConfigContent(data)
	
	if err := os.WriteFile(filePath, []byte(content), 0644); err != nil {
		http.Error(w, "Ошибка сохранения", http.StatusInternalServerError)
		return
	}

	restartAdGuardWithCleanup()
	respondJSON(w, map[string]bool{"success": true})
}

func buildConfigContent(data map[string][]map[string]interface{}) string {
	var lines []string
	
	for ipset, entries := range data {
		for _, entry := range entries {
			if desc, ok := entry["description"].(string); ok && strings.TrimSpace(desc) != "" {
				lines = append(lines, "##"+desc)
			}
			
			line := entry["domains"].(string)
			if !entry["active"].(bool) {
				line = "#" + line
			}
			lines = append(lines, line+"/"+ipset)
		}
	}
	
	return strings.Join(lines, "\n")
}

func restartAdGuardWithCleanup() {
	exec.Command(aghServicePath, "stop").Run()
	
	ipsets := []string{"hr1", "hr2", "hr3"}
	for _, ipset := range ipsets {
		exec.Command("ipset", "flush", ipset).Run()
	}
	
	exec.Command(aghServicePath, "start").Run()
}

func interfacesHandler(w http.ResponseWriter, r *http.Request) {
	policyNames := []string{"HydraRoute1st", "HydraRoute2nd", "HydraRoute3rd"}
	
	policies, err := fetchPolicies()
	if err != nil {
		http.Error(w, "Ошибка получения политик", http.StatusInternalServerError)
		return
	}
	
	interfaces, err := fetchInterfaces()
	if err != nil {
		http.Error(w, "Ошибка получения интерфейсов", http.StatusInternalServerError)
		return
	}
	
	result := buildInterfaceResult(policyNames, policies, interfaces)
	respondJSON(w, result)
}

func fetchPolicies() (map[string]interface{}, error) {
	output, err := exec.Command("curl", "-kfsS", "localhost:79/rci/show/ip/policy/").Output()
	if err != nil {
		return nil, err
	}
	
	var policies map[string]interface{}
	err = json.Unmarshal(output, &policies)
	return policies, err
}

func fetchInterfaces() ([]map[string]interface{}, error) {
	output, err := exec.Command("curl", "-kfsS", "localhost:79/rci/show/interface/").Output()
	if err != nil {
		return nil, err
	}
	
	var ifaceMap map[string]interface{}
	if err := json.Unmarshal(output, &ifaceMap); err != nil {
		return nil, err
	}
	
	var interfaces []map[string]interface{}
	for _, v := range ifaceMap {
		interfaces = append(interfaces, v.(map[string]interface{}))
	}
	
	return interfaces, nil
}

func buildInterfaceResult(policyNames []string, policies map[string]interface{}, interfaces []map[string]interface{}) []string {
	getDescription := func(id string) string {
		for _, iface := range interfaces {
			if iface["id"] == id {
				if desc, ok := iface["description"].(string); ok {
					return desc
				}
			}
		}
		return "Null"
	}

	var result []string
	for _, policyName := range policyNames {
		interfaceID := getDefaultRouteInterface(policies[policyName])
		if interfaceID == "Null" {
			result = append(result, "Null")
		} else {
			result = append(result, getDescription(interfaceID))
		}
	}
	
	return result
}

func getDefaultRouteInterface(policy interface{}) string {
	if policy == nil {
		return "Null"
	}
	
	entry := policy.(map[string]interface{})
	route4, ok := entry["route4"].(map[string]interface{})
	if !ok {
		return "Null"
	}
	
	routes, ok := route4["route"].([]interface{})
	if !ok {
		return "Null"
	}
	
	for _, r := range routes {
		route := r.(map[string]interface{})
		if route["destination"] == "0.0.0.0/0" {
			if iface, ok := route["interface"].(string); ok {
				return iface
			}
		}
	}
	
	return "Null"
}

func proxyFetchHandler(w http.ResponseWriter, r *http.Request) {
	url := r.URL.Query().Get("url")
	if url == "" {
		http.Error(w, "Missing URL", http.StatusBadRequest)
		return
	}

	resp, err := http.Get(url)
	if err != nil || resp.StatusCode != http.StatusOK {
		http.Error(w, "Failed to fetch resource", http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	w.Header().Set("Content-Type", "text/plain")
	io.Copy(w, resp.Body)
}

func respondJSON(w http.ResponseWriter, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(data)
}