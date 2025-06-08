const DOM = {
    modal: null,
    modalTitle: null,
    modalMessage: null,
    modalButton: null,
    dashboardContent: null,
    adguardContent: null,
    infoContent: null,
    settingsContent: null,
    domainsContainer: null,
    addFieldButton: null,
    saveButton: null,
    resetButton: null,
    githubButton: null,
    urlButton: null,
    policyButtons: null,
    sidebarIcons: null,
    
    init() {
        this.modal = document.getElementById('modal');
        this.modalTitle = document.getElementById('modal-title');
        this.modalMessage = document.getElementById('modal-message');
        this.modalButton = document.querySelector('.modal-content button');
        this.dashboardContent = document.getElementById('dashboard-content');
        this.adguardContent = document.getElementById('adguard-content');
        this.infoContent = document.getElementById('info-content');
        this.settingsContent = document.getElementById('settings-content');
        this.domainsContainer = document.getElementById('dashboard-domains-container');
        this.addFieldButton = document.getElementById('dashboard-add-field');
        this.saveButton = document.getElementById('dashboard-save');
        this.resetButton = document.getElementById('dashboard-reset');
        this.githubButton = document.getElementById('load-from-github');
        this.urlButton = document.getElementById('load-from-url');
        this.policyButtons = document.querySelectorAll('.dashboard-policy-btn');
        this.sidebarIcons = document.querySelectorAll('.sidebar .icon');
    }
};

const CONSTANTS = {
    POLICY_NAMES: { hr1: "HydraRoute1st", hr2: "HydraRoute2nd", hr3: "HydraRoute3rd" },
    CONTENT_IDS: ['dashboard-content', 'adguard-content', 'info-content', 'settings-content'],
    PROGRESS_INTERVAL: 150,
    PROGRESS_STEPS: 100
};

const AppState = {
    allData: { hr1: [], hr2: [], hr3: [] },
    activePolicy: "hr1",
    interfaces: ["Null", "Null", "Null"]
};

const Utils = {
    sanitizeInput(input, forUi = false) {
        input = input.trim();
        if (!input.length) return '';
        
        input = input.replace(/[\r\n:; ]+/g, ',')
                    .replace(/,+/g, ',')
                    .replace(/[^a-zA-Z0-9#.,-]/g, '');
        
        const validDomains = input.split(',').filter(domain => /\w+\.\w{2,}$/.test(domain));
        return validDomains.length > 0 ? validDomains.join(forUi ? ', ' : ',') : '';
    },

    getRootDomain(domain) {
        const clean = domain.trim().replace(/^\.+|\.+$/g, '');
        const parts = clean.split('.').filter(Boolean);
        return parts.length <= 2 ? clean : parts.slice(-2).join('.');
    },

    getSecondLevelDomain(domain) {
        const parts = domain.split('.');
        return parts.length > 2 ? parts.slice(-2).join('.') : domain;
    },

    consolidateDomains(domains) {
        if (!domains || domains.length === 0) return [];
        
        const uniqueDomains = [...new Set(domains.map(d => d.trim()).filter(Boolean))];
        
        const rootGroups = {};
        
        uniqueDomains.forEach(domain => {
            const root = this.getRootDomain(domain);
            if (!rootGroups[root]) {
                rootGroups[root] = [];
            }
            rootGroups[root].push(domain);
        });
        
        const result = [];
        
        Object.values(rootGroups).forEach(domainGroup => {
            if (domainGroup.length === 1) {
                result.push(domainGroup[0]);
                return;
            }
            
            const sortedDomains = domainGroup.sort((a, b) => {
                return a.split('.').length - b.split('.').length;
            });
            
            const minimalSet = [];
            
            for (const domain of sortedDomains) {
                let isCovered = false;
                
                for (const existing of minimalSet) {
                    if (this.isDomainCovered(domain, existing)) {
                        isCovered = true;
                        break;
                    }
                }
                
                if (!isCovered) {
                    minimalSet.push(domain);
                }
            }
            
            result.push(...minimalSet);
        });
        
        return result;
    },

    isDomainCovered(subdomain, parentDomain) {
        if (subdomain === parentDomain) {
            return true;
        }
        
        
        const subParts = subdomain.split('.');
        const parentParts = parentDomain.split('.');
        
        if (parentParts.length >= subParts.length) {
            return false;
        }
        
        const parentSuffix = '.' + parentDomain;
        return subdomain.endsWith(parentSuffix);
    },

    debounce(func, delay) {
        let timeoutId;
        return function (...args) {
            clearTimeout(timeoutId);
            timeoutId = setTimeout(() => func.apply(this, args), delay);
        };
    }
};

const Modal = {
    open(title, message) {
        DOM.modalTitle.textContent = title;
        DOM.modalMessage.innerHTML = message;

        if (message.includes('Войдите снова')) {
            DOM.modalButton.textContent = "Войти";
            DOM.modalButton.onclick = () => window.location.href = "/login";
        } else {
            DOM.modalButton.textContent = "Закрыть";
            DOM.modalButton.onclick = this.close;
        }

        DOM.modal.style.display = 'block';
    },

    close() {
        DOM.modal.style.display = 'none';
    }
};

const ContentManager = {
    hideAll() {
        CONSTANTS.CONTENT_IDS.forEach(id => {
            const element = document.getElementById(id);
            if (element) element.style.display = 'none';
        });
    },

    show(contentId) {
        this.hideAll();
        const content = document.getElementById(contentId);
        if (content) content.style.display = 'block';
        
        this.updateActiveIcon(contentId);
    },

    updateActiveIcon(contentId) {
        DOM.sidebarIcons.forEach(icon => icon.classList.remove('active'));
        
        const iconIndex = Array.from(DOM.sidebarIcons).findIndex(icon => {
            const alt = icon.querySelector('img')?.alt?.toLowerCase();
            return alt?.includes(contentId.replace('-content', ''));
        });
        
        if (iconIndex !== -1) {
            DOM.sidebarIcons[iconIndex].classList.add('active');
        }
    },

    initSidebarEvents() {
        DOM.sidebarIcons.forEach((icon, index) => {
            icon.addEventListener('click', () => {
                this.show(CONSTANTS.CONTENT_IDS[index]);
            });
        });
    }
};

const API = {
    async request(url, options = {}) {
        try {
            const response = await fetch(url, options);
            
            if (!response.ok) {
                if (response.status === 401) {
                    window.location.href = "/login";
                    return;
                }
                throw new Error(`HTTP ${response.status}`);
            }
            
            return response;
        } catch (error) {
            console.error(`API Error [${url}]:`, error);
            throw error;
        }
    },

    async getInterfaces() {
        try {
            const response = await this.request('/interfaces');
            return await response.json();
        } catch {
            return ["Null", "Null", "Null"];
        }
    },

    async loadConfig() {
        try {
            const response = await this.request('/config');
            return await response.json();
        } catch (error) {
            Modal.open('Ошибка', 'Сессия истекла.<br><br>Войдите снова.');
            throw error;
        }
    },

    async saveConfig(data) {
        const response = await this.request('/save', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(data)
        });
        return await response.json();
    },

    async loadServices() {
        try {
            const response = await this.request('/load-services');
            return await response.json();
        } catch {
            return [];
        }
    },

    async fetchDomains(url) {
        const response = await this.request(`/proxy-fetch?url=${encodeURIComponent(url)}`);
        return await response.text();
    }
};

const PolicyManager = {
    save() {
        AppState.allData[AppState.activePolicy] = [...DOM.domainsContainer.children]
            .map(div => {
                const sanitizedDomains = Utils.sanitizeInput(div.querySelector("textarea").value);
                const description = div.querySelector(".description").value.trim();
                const active = div.querySelector("input[type='checkbox']").checked;
                
                return sanitizedDomains ? { domains: sanitizedDomains, active, description } : null;
            })
            .filter(Boolean);
    },

    load(policy) {
        DOM.domainsContainer.innerHTML = "";
        AppState.allData[policy].forEach(item => {
            DomainManager.addField(item.domains, item.active, item.description || '');
        });
    },

    switch(newPolicy) {
        this.save();
        AppState.activePolicy = newPolicy;
        this.load(newPolicy);
    },

    async updateButtons() {
        AppState.interfaces = await API.getInterfaces();
        
        DOM.policyButtons.forEach((button, index) => {
            const policyName = button.getAttribute('data-ipset');
            let interfaceName = AppState.interfaces[index] || 'Null';
            
            if (interfaceName === 'Null') {
                interfaceName = 'Нет активного подключения';
            }

            button.innerHTML = `
                <div class="polici-name">${CONSTANTS.POLICY_NAMES[policyName]}</div>
                <div class="interface-name">${interfaceName}</div>
            `;
        });
    }
};

const DomainManager = {
    addField(value = "", active = true, description = "") {
        const div = document.createElement("div");
        div.classList.add("domain-entry");
        div.innerHTML = `
            <div class="domain-entry-wrapper">
                <label class="domain-entry">
                    <input type="checkbox" ${active ? "checked" : ""}>
                    <div class="domain-checkbox">
                        <img src="/assets/sprite/check-mark-small.svg" alt="✓">
                    </div>
                </label>
                <div class="domain-content">
                    <div class="domain-controls">
                        <input type="text" class="description" value="${description}" placeholder="Описание">
                    </div>
                    <textarea>${Utils.sanitizeInput(value, true)}</textarea>
                    <div class="remove-container">
                        <button class="remove">
                            <img src="/assets/sprite/delete.svg" alt="Удалить" class="delete-icon">
                            <span>удалить</span>
                        </button>
                    </div>
                </div>
            </div>
        `;
        
        DOM.domainsContainer.appendChild(div);
        div.querySelector(".remove").addEventListener("click", () => div.remove());
    },

    addFromList(domains, source = 'Загружено по ссылке') {
        if (domains.length > 0) {
            const grouped = domains.join(',');
            this.addField(grouped, true, source);
        }
    },

    getExistingRootDomains() {
        const domainsOnPage = new Set();

        Object.values(AppState.allData).forEach(entries => {
            entries.forEach(entry => {
                if (!entry.domains) return;
                entry.domains.split(',').forEach(domain => {
                    const cleaned = domain.trim();
                    if (cleaned) {
                        domainsOnPage.add(Utils.getRootDomain(cleaned));
                    }
                });
            });
        });

        return domainsOnPage;
    },

    async loadFromGithub(serviceUrls) {
        if (!Array.isArray(serviceUrls) || serviceUrls.length === 0) return [];

        const existingRoots = this.getExistingRootDomains();
        const allDomains = new Set();

        for (const url of serviceUrls) {
            try {
                const text = await API.fetchDomains(url);
                const lines = text.replace(/\uFEFF/g, '').split('\n');

                lines.forEach(line => {
                    const domain = line.trim();
                    if (domain) {
                        const root = Utils.getRootDomain(domain);
                        if (!existingRoots.has(root)) {
                            allDomains.add(domain);
                        }
                    }
                });
            } catch (e) {
                console.warn(`Ошибка загрузки ${url}:`, e);
            }
        }

        return Utils.consolidateDomains([...allDomains]);
    }
};

const Validator = {
    validateData(forceOverride = false) {
        const policyDomains = new Map();
        const domainConflicts = new Map();
        const activePolicies = new Set();

        Object.keys(AppState.allData).forEach(policy => {
            const domains = new Set();
            
            AppState.allData[policy].forEach(entry => {
                if (!entry.active) return;

                const entryDomains = entry.domains.split(',').map(d => d.trim()).filter(Boolean);
                entryDomains.forEach(domain => domains.add(domain));
            });
            
            if (domains.size > 0) {
                policyDomains.set(policy, domains);
            }
        });

        const policies = Array.from(policyDomains.keys());
        
        for (let i = 0; i < policies.length; i++) {
            for (let j = i + 1; j < policies.length; j++) {
                const policy1 = policies[i];
                const policy2 = policies[j];
                const domains1 = policyDomains.get(policy1);
                const domains2 = policyDomains.get(policy2);
                
                const conflicts = this.findDomainConflicts(domains1, domains2);
                
                if (conflicts.length > 0) {
                    activePolicies.add(policy1);
                    activePolicies.add(policy2);
                    
                    conflicts.forEach(domain => {
                        if (!domainConflicts.has(domain)) {
                            domainConflicts.set(domain, new Set());
                        }
                        domainConflicts.get(domain).add(policy1);
                        domainConflicts.get(domain).add(policy2);
                    });
                }
            }
        }

        policyDomains.forEach((domains, policy) => {
            const internalConflicts = this.findInternalConflicts(domains);
            
            if (internalConflicts.length > 0) {
                activePolicies.add(policy);
                
                internalConflicts.forEach(domain => {
                    if (!domainConflicts.has(domain)) {
                        domainConflicts.set(domain, new Set());
                    }
                    domainConflicts.get(domain).add(policy);
                });
            }
        });

        if (domainConflicts.size > 0 && !forceOverride) {
            this.showValidationWarning(domainConflicts, activePolicies);
            return false;
        }

        return true;
    },

    findDomainConflicts(domains1, domains2) {
        const conflicts = [];
        
        domains1.forEach(domain1 => {
            domains2.forEach(domain2 => {
                if (this.domainsConflict(domain1, domain2)) {
                    if (domain1 === domain2) {
                        conflicts.push(domain1);
                    } else {
                        if (Utils.isDomainCovered(domain1, domain2)) {
                            conflicts.push(domain2);
                        } else if (Utils.isDomainCovered(domain2, domain1)) {
                            conflicts.push(domain1);
                        } else {
                            conflicts.push(domain1, domain2);
                        }
                    }
                }
            });
        });
        
        return [...new Set(conflicts)];
    },

    findInternalConflicts(domains) {
        const conflicts = [];
        const domainArray = Array.from(domains);
        
        for (let i = 0; i < domainArray.length; i++) {
            for (let j = i + 1; j < domainArray.length; j++) {
                if (this.domainsConflict(domainArray[i], domainArray[j])) {
                    if (Utils.isDomainCovered(domainArray[j], domainArray[i])) {
                        conflicts.push(domainArray[i]);
                    } else if (Utils.isDomainCovered(domainArray[i], domainArray[j])) {
                        conflicts.push(domainArray[j]);
                    }
                }
            }
        }
        
        return [...new Set(conflicts)];
    },

    domainsConflict(domain1, domain2) {
        
        if (domain1 === domain2) {
            return true;
        }
        
        if (Utils.isDomainCovered(domain1, domain2) || Utils.isDomainCovered(domain2, domain1)) {
            return true;
        }
        
        const root1 = Utils.getRootDomain(domain1);
        const root2 = Utils.getRootDomain(domain2);
        
        return root1 === root2;
    },

    addDomainError(domainErrors, domain, policy) {
        if (!domainErrors.has(domain)) {
            domainErrors.set(domain, new Set());
        }
        domainErrors.get(domain).add(policy);
    },

    showValidationWarning(domainErrors, activePolicies) {
       const policies = Array.from(activePolicies);
       let tableHTML = '<table border="1" style="width:100%; border-collapse: collapse; margin-bottom: 20px;">';
       
       tableHTML += '<tr>';
       policies.forEach(policy => {
           tableHTML += `<th style="padding: 8px; background-color: #f5f5f5;">${CONSTANTS.POLICY_NAMES[policy]}</th>`;
       });
       tableHTML += '</tr>';
    
       domainErrors.forEach((policiesSet, domain) => {
           tableHTML += '<tr>';
           policies.forEach(policy => {
               const cellContent = policiesSet.has(policy) ? domain : '';
               tableHTML += `<td style="padding: 8px; text-align: center; word-break: break-all;">${cellContent}</td>`;
           });
           tableHTML += '</tr>';
       });
    
       tableHTML += '</table>';
       tableHTML += '<div style="margin-bottom: 15px; color: #666;">Обнаружены пересекающиеся или вложенные домены. Это может привести к непредсказуемому поведению маршрутизации.</div>';
       tableHTML += '<div style="display: flex; gap: 10px; justify-content: center;">';
       tableHTML += '<button id="continue-save" style="background-color: #ff6b6b; color: white; padding: 10px 20px; border: none; border-radius: 4px; cursor: pointer;">Продолжить сохранение</button>';
       tableHTML += '</div>';
    
       DOM.modalTitle.textContent = "Предупреждение о пересечении доменов";
       DOM.modalMessage.innerHTML = tableHTML;
       DOM.modal.style.display = 'block';
    
       DOM.modalButton.textContent = "Закрыть";
       DOM.modalButton.onclick = Modal.close;
    
       document.getElementById('continue-save').addEventListener('click', () => {
           Modal.close();
           App.forceSave();
       });
    }
};

const Loaders = {
    async loadFromGithub() {
        const selectedServices = Array.from(document.querySelectorAll('input[name="services[]"]:checked'))
            .map(input => input.value);

        if (selectedServices.length === 0) {
            Modal.open('Ошибка', 'Выберите хотя бы один сервис.');
            return;
        }

        try {
            const domains = await DomainManager.loadFromGithub(selectedServices);
            if (domains.length === 0) {
                Modal.open('Информация', 'Новых доменов не найдено.');
                return;
            }
            
            DomainManager.addFromList(domains, 'Загружено с GitHub');
            this.resetCheckboxes();
            Modal.close();
        } catch (error) {
            console.error('Ошибка загрузки:', error);
            Modal.open('Ошибка', 'Ошибка при загрузке доменов.');
        }
    },

    resetCheckboxes() {
        document.querySelectorAll('input[name="services[]"]').forEach(checkbox => {
            checkbox.checked = false;
        });
    },

    async loadAllData() {
        try {
            const data = await API.loadConfig();
            if (data) {
                AppState.allData = data;
                PolicyManager.load(AppState.activePolicy);
            }
        } catch (error) {
            console.error("Ошибка загрузки данных:", error);
        }
    }
};

const App = {
    async init() {
        DOM.init();
        await this.setupEventListeners();
        await PolicyManager.updateButtons();
        await Loaders.loadAllData();
        ContentManager.show('dashboard-content');
        this.initAdditionalFeatures();
    },

    async setupEventListeners() {
        ContentManager.initSidebarEvents();

        DOM.policyButtons.forEach(button => {
            button.addEventListener("click", () => {
                DOM.policyButtons.forEach(btn => btn.classList.remove("active"));
                button.classList.add("active");
                PolicyManager.switch(button.getAttribute("data-ipset"));
            });
        });

        DOM.addFieldButton.addEventListener("click", () => DomainManager.addField());
        DOM.saveButton.addEventListener("click", this.handleSave.bind(this));
        DOM.resetButton.addEventListener("click", () => Loaders.loadAllData());

        DOM.githubButton.addEventListener("click", this.handleGithubLoad.bind(this));
        DOM.urlButton.addEventListener("click", this.handleUrlLoad.bind(this));

        document.querySelectorAll('.description-header').forEach(header => {
            const content = header.nextElementSibling;
            const toggleButton = header.querySelector('.description-toggle');
            
            header.addEventListener('click', () => {
                const isExpanded = content.classList.toggle('expanded');
                toggleButton.classList.toggle('rotated', isExpanded);
            });
        });

        const passwordForm = document.getElementById('change-password-form');
        if (passwordForm) {
            passwordForm.addEventListener('submit', this.handlePasswordChange.bind(this));
        }
    },

    async handleSave() {
        PolicyManager.save();

        if (!Validator.validateData()) return;

        await this.performSave();
    },

    async forceSave() {
        await this.performSave();
    },

    async performSave() {
        try {
            const result = await API.saveConfig(AppState.allData);
            
            if (result.success) {
                this.showSaveProgress();
                await Loaders.loadAllData();
            } else {
                Modal.open("Ошибка", "Что-то пошло не так: " + (result.error || "Неизвестная ошибка"));
            }
        } catch (error) {
            console.error("Ошибка сохранения:", error);
            Modal.open("Ошибка", "Ошибка сохранения: " + error.message);
        }
    },

    showSaveProgress() {
       const loaderHTML = `
           <div id="dns-loader" style="display: flex; flex-direction: column; align-items: center;">
               <p>Запуск DNS сервера, подождите...</p>
               <div style="width: 100%; background-color: #f3f3f3; border-radius: 4px; height: 20px; margin-top: 10px;">
                   <div id="dns-progress" style="height: 100%; width: 0%; background-color: #2396da; border-radius: 4px;"></div>
               </div>
           </div>
       `;
       Modal.open("Сохранено", loaderHTML);
    
       const totalDuration = 5000;
       const startTime = performance.now();
       
       const updateProgress = () => {
           const currentTime = performance.now();
           const elapsed = currentTime - startTime;
           const progress = Math.min((elapsed / totalDuration) * 100, 100);
           
           const progressElement = document.getElementById('dns-progress');
           if (progressElement) {
               progressElement.style.width = progress + '%';
           }
           
           if (progress >= 100) {
               const messageElement = document.getElementById('modal-message');
               if (messageElement) {
                   messageElement.innerHTML = '<p>DNS сервер успешно перезапущен.</p>';
               }
           } else {
               requestAnimationFrame(updateProgress);
           }
       };
       
       requestAnimationFrame(updateProgress);
    },

    async handleGithubLoad() {
        Modal.open("Загрузка сервисов", `
            <div id="service-loading-message" style="display: none;">Загрузка...</div>
            <div class="service-list-container">
                <ul id="service-list"></ul>
            </div>
            <button id="confirm-service-load">Добавить</button>
        `);

        const services = await API.loadServices();
        const list = document.getElementById("service-list");

        if (services.length === 0) {
            list.innerHTML = "<li>Не удалось загрузить список сервисов</li>";
            return;
        }

        services.forEach(service => {
            const li = document.createElement("li");
            li.innerHTML = `
                <label class="domain-entry" style="display: flex; align-items: center; gap: 10px;">
                    <input type="checkbox" name="services[]" value="${service.url}">
                    <div class="domain-checkbox"><img src="/assets/sprite/check-mark-small.svg" alt="✓"></div>
                    <span class="checkbox-label-text">${service.name}</span>
                </label>
            `;
            list.appendChild(li);
        });

        document.getElementById("confirm-service-load").addEventListener("click", () => {
            Loaders.loadFromGithub();
        });
    },

    handleUrlLoad() {
        Modal.open("Загрузка по ссылке", `
            <p>Укажите ссылку на файл со списком доменов:</p>
            <input type="text" id="custom-url" placeholder="https://example.com/domains.txt" style="width: 100%; padding: 8px; margin-top: 10px;">
            <button id="confirm-url-load" style="margin-top: 15px;">Загрузить</button>
        `);

        document.getElementById("confirm-url-load").addEventListener("click", async () => {
            const input = document.getElementById("custom-url").value.trim();
            
            if (!input.startsWith("http")) {
                Modal.open("Ошибка", "Неверная ссылка.");
                return;
            }

            try {
                const domains = await DomainManager.loadFromGithub([input]);
                if (domains.length === 0) {
                    Modal.open("Информация", "Новых доменов не найдено.");
                    return;
                }
                
                DomainManager.addFromList(domains);
                Modal.close();
            } catch (error) {
                console.error('Ошибка загрузки по ссылке:', error);
                Modal.open('Ошибка', 'Не удалось загрузить домены по указанной ссылке.');
            }
        });
    },

    async handlePasswordChange(event) {
        event.preventDefault();

        const currentPassword = document.getElementById('current-password').value;
        const newPassword = document.getElementById('new-password').value;
        const confirmPassword = document.getElementById('confirm-password').value;
        const messageElement = document.getElementById('password-change-message');

        if (newPassword !== confirmPassword) {
            messageElement.textContent = 'Новый пароль и подтверждение не совпадают.';
            return;
        }

        try {
            const response = await API.request('/change-password', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ currentPassword, newPassword })
            });

            const result = await response.json();
            messageElement.textContent = result.success 
                ? 'Пароль успешно изменен.' 
                : (result.error || 'Ошибка при смене пароля.');
        } catch (error) {
            messageElement.textContent = 'Ошибка при отправке запроса.';
        }
    },

    initAdditionalFeatures() {
        this.initAdGuardIP();
        
        this.updateAdGuardStatus();
        
        this.initAdGuardRestart();
        
        if (DOM.policyButtons.length > 0) {
            DOM.policyButtons[0].classList.add("active");
        }
    },

    async initAdGuardIP() {
        try {
            const response = await API.request('/br0ip');
            const data = await response.json();
            
            if (data.ip) {
                const adguardLink = document.getElementById('adguard-link');
                if (adguardLink) {
                    adguardLink.href = `http://${data.ip}:3000`;
                }
            }
        } catch (error) {
            console.error('Ошибка получения IP:', error);
            Modal.open('Ошибка', 'Ошибка получения IP: ' + error.message);
        }
    },

    async updateAdGuardStatus() {
        try {
            const response = await API.request('/agh-status');
            const data = await response.text();
            
            const statusElement = document.getElementById('adguard-status');
            if (statusElement) {
                statusElement.textContent = `Статус: ${data}`;
            }
        } catch (error) {
            const statusElement = document.getElementById('adguard-status');
            if (statusElement) {
                statusElement.textContent = 'Ошибка при получении статуса';
            }
        }
    },

    initAdGuardRestart() {
        const restartButton = document.getElementById('adguard-restart-button');
        if (restartButton) {
            restartButton.addEventListener('click', async (event) => {
                event.preventDefault();
                
                try {
                    const response = await API.request('/agh-restart', { method: 'POST' });
                    const data = await response.text();
                    
                    Modal.open('Успех', data);
                    this.updateAdGuardStatus();
                } catch (error) {
                    Modal.open('Ошибка', error.message);
                }
            });
        }
    }
};

function logout() {
    fetch('/logout', { method: 'GET' })
        .then(response => {
            if (response.redirected) {
                window.location.href = response.url;
            }
        })
        .catch(error => {
            console.error('Ошибка при выходе из системы:', error);
            Modal.open('Ошибка', 'Ошибка при выходе из системы');
        });
}

document.addEventListener('DOMContentLoaded', () => {
    App.init();
});