function openModal(title, message) {
	const modal = document.getElementById('modal');
	const modalTitle = document.getElementById('modal-title');
	const modalMessage = document.getElementById('modal-message');
	const modalButton = document.querySelector('.modal-content button');

	modalTitle.textContent = title;
	modalMessage.innerHTML = message;

	if (message.includes('Войдите снова')) {
		modalButton.textContent = "Войти";
		modalButton.onclick = () => window.location.href = "/login";
	} else {
		modalButton.textContent = "Закрыть";
		modalButton.onclick = closeModal;
	}

	modal.style.display = 'block';
}

function closeModal() {
	const modal = document.getElementById('modal');
	modal.style.display = 'none';
}

function hideAllContent() {
	document.getElementById('dashboard-content').style.display = 'none';
	document.getElementById('adguard-content').style.display = 'none';
	document.getElementById('info-content').style.display = 'none';
	document.getElementById('settings-content').style.display = 'none';
}

document.querySelector('.sidebar .icon:nth-child(1)').addEventListener('click', () => showContent('dashboard-content'));
document.querySelector('.sidebar .icon:nth-child(2)').addEventListener('click', () => showContent('adguard-content'));
document.querySelector('.sidebar .icon:nth-child(3)').addEventListener('click', () => showContent('info-content'));
document.querySelector('.sidebar .icon:nth-child(4)').addEventListener('click', () => showContent('settings-content'));

showContent('dashboard-content');

function showContent(contentId) {
	hideAllContent();
	document.getElementById(contentId).style.display = 'block';
	document.querySelectorAll('.sidebar .icon').forEach(icon => {
		icon.classList.remove('active');
	});
	const iconIndex = Array.from(document.querySelectorAll('.sidebar .icon')).findIndex(icon => {
		return icon.querySelector('img').alt.toLowerCase().includes(contentId.replace('-content', ''));
	});
	if (iconIndex !== -1) {
		document.querySelectorAll('.sidebar .icon')[iconIndex].classList.add('active');
	}
}

document.addEventListener('DOMContentLoaded', function () {
	document.querySelectorAll('.description-header').forEach(header => {
		const content = header.nextElementSibling;
		const toggleButton = header.querySelector('.description-toggle');
		header.addEventListener('click', function () {
			const isExpanded = content.classList.toggle('expanded');
			toggleButton.classList.toggle('rotated', isExpanded);
		});
	});
});

let allData = { hr1: [], hr2: [], hr3: [] };

document.addEventListener("DOMContentLoaded", async () => {
    let activePolicy = "hr1";
    const policyNames = { hr1: "HydraRoute1st", hr2: "HydraRoute2nd", hr3: "HydraRoute3rd" };
    const domainsContainer = document.getElementById("dashboard-domains-container");
    const addFieldButton = document.getElementById("dashboard-add-field");
    const saveButton = document.getElementById("dashboard-save");
    const resetButton = document.getElementById("dashboard-reset");
	const githubButton = document.getElementById("load-from-github");
	githubButton.addEventListener("click", async () => {
		openModal("Загрузка сервисов", `
			<div id="service-loading-message" style="display: none;">Загрузка...</div>
			<div class="service-list-container">
				<ul id="service-list"></ul>
			</div>
			<button id="confirm-service-load">Добавить</button>
		`);

		const services = await fetch("/load-services").then(r => r.json()).catch(() => []);
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
					<div class="domain-checkbox"><img src="/static/assets/sprite/check-mark-small.svg" alt="✓"></div>
					<span class="checkbox-label-text">${service.name}</span>
				</label>
			`;
			list.appendChild(li);
		});

		document.getElementById("confirm-service-load").addEventListener("click", loadFromGithub);
	});

	const urlButton = document.getElementById("load-from-url");
	urlButton.addEventListener("click", () => {
		openModal("Загрузка по ссылке", `
			<p>Укажите ссылку на файл со списком доменов:</p>
			<input type="text" id="custom-url" placeholder="https://example.com/domains.txt" style="width: 100%; padding: 8px; margin-top: 10px;">
			<button id="confirm-url-load" style="margin-top: 15px;">Загрузить</button>
		`);

		document.getElementById("confirm-url-load").addEventListener("click", async () => {
			const input = document.getElementById("custom-url").value.trim();
			if (!input.startsWith("http")) {
				openModal("Ошибка", "Неверная ссылка.");
				return;
			}

			try {
				const domains = await loadDomainsFromGithub([input]); // использует уже существующую функцию
				if (domains.length === 0) {
					openModal("Информация", "Новых доменов не найдено.");
					return;
				}
				addDomainsToField(domains);
				closeModal();
			} catch (error) {
				console.error('Ошибка загрузки по ссылке:', error);
				openModal('Ошибка', 'Не удалось загрузить домены по указанной ссылке.');
			}
		});
	});

    const policyButtons = document.querySelectorAll(".dashboard-policy-btn");
	policyButtons[0].classList.add("active");
	async function getInterfaces() {
		try {
			const response = await fetch('/interfaces');
			return await response.json();
		} catch (error) {
			return ["Null", "Null", "Null"];
		}
	}

	async function updatePolicyButtons() {
		const interfaces = await getInterfaces();
		policyButtons.forEach((button, index) => {
			const policyName = button.getAttribute('data-ipset');
			let interfaceName = interfaces[index] || 'Null';
			
			if (interfaceName === 'Null') {
				interfaceName = 'Нет активного подключения';
			}

			button.innerHTML = `
				<div class="polici-name">${policyNames[policyName]}</div>
				<div class="interface-name">${interfaceName}</div>
			`;
		});
	}

    updatePolicyButtons();

    function sanitizeInput(input, forUi = false) {
        input = input.trim();
        if (input.length === 0) return '';
        input = input.replace(/[\r\n:; ]+/g, ',');
        input = input.replace(/,+/g, ',');
        input = input.replace(/[^a-zA-Z0-9#.,-]/g, '');
        input = input.split(',').filter(domain => /\w+\.\w{2,}$/.test(domain));
        return input.length > 0 ? input.join(forUi ? ', ' : ',') : '';
    }

	function saveCurrentPolicy() {
		allData[activePolicy] = [...domainsContainer.children]
			.map(div => {
				const sanitizedDomains = sanitizeInput(div.querySelector("textarea").value);
				const description = div.querySelector(".description").value.trim();
				return sanitizedDomains ? { domains: sanitizedDomains, active: div.querySelector("input[type='checkbox']").checked, description } : null;
			})
			.filter(entry => entry !== null);
	}

	function loadPolicy(policy) {
		domainsContainer.innerHTML = "";
		allData[policy].forEach(item => addDomainField(item.domains, item.active, item.description || ''));
	}

	function addDomainField(value = "", active = true, description = "") {
		const div = document.createElement("div");
		div.classList.add("domain-entry");
		div.innerHTML = `
			<div class="domain-entry-wrapper">
				<label class="domain-entry">
					<input type="checkbox" ${active ? "checked" : ""}>
					<div class="domain-checkbox">
						<img src="/static/assets/sprite/check-mark-small.svg" alt="✓">
					</div>
				</label>
				<div class="domain-content">
					<div class="domain-controls">
						<input type="text" class="description" value="${description}" placeholder="Описание">
					</div>
					<textarea>${sanitizeInput(value, true)}</textarea>
					<div class="remove-container">
						<button class="remove">
							<img src="/static/assets/sprite/delete.svg" alt="Удалить" class="delete-icon">
							<span>удалить</span>
						</button>
					</div>
				</div>
			</div>
		`;
		domainsContainer.appendChild(div);
		div.querySelector(".remove").addEventListener("click", () => div.remove());
	}

	function addDomainsToField(domains, source = 'Загружено по ссылке') {
		const grouped = domains.length > 0 ? domains.join(',') : '';
		if (grouped) {
			addDomainField(grouped, true, source);
		}
	}

	function resetCheckboxes() {
		const checkboxes = document.querySelectorAll('input[name="services[]"]');
		checkboxes.forEach(checkbox => checkbox.checked = false);
	}

	async function loadFromGithub() {
		const selectedServices = Array.from(document.querySelectorAll('input[name="services[]"]:checked'))
			.map(input => input.value);

		if (selectedServices.length === 0) {
			openModal('Ошибка', 'Выберите хотя бы один сервис.');
			return;
		}

		try {
			const domains = await loadDomainsFromGithub(selectedServices);
			if (domains.length === 0) {
				openModal('Информация', 'Новых доменов не найдено.');
				return;
			}
			addDomainsToField(domains, 'Загружено с GitHub');
			resetCheckboxes();
			closeModal();
		} catch (error) {
			console.error('Ошибка загрузки:', error);
			openModal('Ошибка', 'Ошибка при загрузке доменов.');
		}
	}

	function loadAllData() {
		fetch("/config")
			.then(response => {
				if (!response.ok) {
					if (response.status === 401) {
						window.location.href = "/login";
						return;
					}
					throw new Error('Ошибка загрузки данных');
				}
				return response.json();
			})
			.then(data => {
				if (!data) return;
				allData = data;
				loadPolicy(activePolicy);
			})
			.catch(error => {
				console.error("Ошибка загрузки данных:", error);
				openModal('Ошибка', 'Сессия истекла.<br><br>Войдите снова.');
			});
	}

    function getSecondLevelDomain(domain) {
        const parts = domain.split('.');
        return parts.length > 2 ? parts.slice(-2).join('.') : domain;
    }

	function validateData() {
		const domainMap = new Map();
		let domainErrors = new Map();
		const activePolicies = new Set();

		Object.keys(allData).forEach(policy => {
			const policyDomains = new Set();
			allData[policy].forEach(entry => {
				if (!entry.active) return;

				const domains = entry.domains.split(',').map(d => d.trim());

				domains.forEach(domain => {
					const secondLevel = getSecondLevelDomain(domain);
					
					if (policyDomains.has(secondLevel)) {
						if (!domainErrors.has(secondLevel)) {
							domainErrors.set(secondLevel, new Set());
						}
						domainErrors.get(secondLevel).add(policy);
						activePolicies.add(policy);
					} else {
						policyDomains.add(secondLevel);
					}

					if (domainMap.has(secondLevel) && domainMap.get(secondLevel) !== policy) {
						if (!domainErrors.has(secondLevel)) {
							domainErrors.set(secondLevel, new Set());
						}
						domainErrors.get(secondLevel).add(policy);
						domainErrors.get(secondLevel).add(domainMap.get(secondLevel));
						activePolicies.add(policy);
						activePolicies.add(domainMap.get(secondLevel));
					} else {
						domainMap.set(secondLevel, policy);
					}
				});
			});
		});

		if (domainErrors.size > 0) {
			const policies = Array.from(activePolicies);
			let tableHTML = '<table border="1" style="width:100%; border-collapse: collapse;">';
			
			tableHTML += '<tr>';
			policies.forEach(policy => {
				tableHTML += `<th>${policyNames[policy]}</th>`;
			});
			tableHTML += '</tr>';

			domainErrors.forEach((policiesSet, domain) => {
				tableHTML += '<tr>';
				policies.forEach(policy => {
					if (policiesSet.has(policy)) {
						tableHTML += `<td>${domain}</td>`;
					} else {
						tableHTML += '<td></td>';
					}
				});
				tableHTML += '</tr>';
			});

			tableHTML += '</table>';
			openModal("Пересекающиеся или одинаковые домены", tableHTML);
			return false;
		}

		return true;
	}

    addFieldButton.addEventListener("click", () => addDomainField());

	saveButton.addEventListener("click", () => {
		saveCurrentPolicy();

		if (!validateData()) return;

		fetch("/save", {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify(allData)
		})
		.then(response => response.json())
		.then(result => {
			if (result.success) {
				const loaderHTML = `
					<div id="dns-loader" style="display: flex; flex-direction: column; align-items: center;">
						<p>Запуск DNS сервера, подождите...</p>
						<div style="width: 100%; background-color: #f3f3f3; border-radius: 4px; height: 20px; margin-top: 10px;">
							<div id="dns-progress" style="height: 100%; width: 0%; background-color: #2396da; border-radius: 4px;"></div>
						</div>
					</div>
				`;
				openModal("Сохранено", loaderHTML);

				let progress = 0;
				const interval = setInterval(() => {
					progress += 1;
					document.getElementById('dns-progress').style.width = progress + '%';
					if (progress >= 100) {
						clearInterval(interval);
						document.getElementById('modal-message').innerHTML = '<p>DNS сервер успешно перезапущен.</p>';
					}
				}, 150); // 150 мс * 100 шагов ≈ 15 секунд

				loadAllData();
			} else {
				openModal("Ошибка", "Что-то пошло не так: " + (result.error || "Неизвестная ошибка"));
			}
		})
		.catch(error => {
			console.error("Ошибка сохранения:", error);
			openModal("Ошибка", "Ошибка сохранения: " + error.message);
		});
	});

    resetButton.addEventListener("click", loadAllData);

	policyButtons.forEach(button => {
		button.addEventListener("click", () => {
			policyButtons.forEach(btn => btn.classList.remove("active"));
			button.classList.add("active");
			saveCurrentPolicy();
			activePolicy = button.getAttribute("data-ipset");
			loadPolicy(activePolicy);
		});
	});

    loadAllData();
});

fetch('/br0ip')
    .then(response => response.json())
    .then(data => {
        if (data.ip) {
            document.getElementById('adguard-link').href = `http://${data.ip}:3000`;
        } else {
            console.error('Не удалось получить IP-адрес br0');
            openModal('Ошибка', 'Не удалось получить IP-адрес br0');
        }
    })
    .catch(error => {
        console.error('Ошибка получения IP:', error);
        openModal('Ошибка', 'Ошибка получения IP: ' + error.message);
    });

function updateStatus() {
    fetch('/agh-status')
        .then(response => response.text())
        .then(data => {
            document.getElementById('adguard-status').textContent = `Статус: ${data}`;
        })
        .catch(() => {
            document.getElementById('adguard-status').textContent = 'Ошибка при получении статуса';
            openModal('Ошибка', 'Ошибка при получении статуса');
        });
}

document.getElementById('adguard-restart-button').addEventListener('click', function(event) {
    event.preventDefault();
    fetch('/agh-restart', {
        method: 'POST',
    })
    .then(response => response.text())
    .then(data => {
        openModal('Успех', data);
        updateStatus();
    })
    .catch(error => {
        openModal('Ошибка', error.message);
    });
});

function getRootDomain(domain) {
	const clean = domain.trim().replace(/^\.+|\.+$/g, '');
	const parts = clean.split('.').filter(Boolean);

	if (parts.length <= 2) {
		return clean;
	}
	return parts.slice(-2).join('.');
}

function getExistingRootDomainsFromData() {
	const domainsOnPage = new Set();

	Object.values(allData).forEach(entries => {
		entries.forEach(entry => {
			if (!entry.domains) return;
			entry.domains.split(',').forEach(domain => {
				const cleaned = domain.trim();
				if (cleaned) {
					domainsOnPage.add(getRootDomain(cleaned));
				}
			});
		});
	});

	return domainsOnPage;
}

function consolidateDomains(domains) {
    const rootMap = {};

    domains.forEach(d => {
        const root = getRootDomain(d);
        if (!rootMap[root]) rootMap[root] = [];
        rootMap[root].push(d);
    });

    const consolidated = [];
    for (const [root, list] of Object.entries(rootMap)) {
        if (list.length > 1) {
            consolidated.push(root);
        } else {
            consolidated.push(list[0]);
        }
    }
    return consolidated;
}

async function loadDomainsFromGithub(serviceUrls) {
    if (!Array.isArray(serviceUrls) || serviceUrls.length === 0) return [];

    const existingRoots = getExistingRootDomainsFromData();
    const allDomains = new Set();

    for (const url of serviceUrls) {
        try {
            const response = await fetch(`/proxy-fetch?url=${encodeURIComponent(url)}`);
            const text = await response.text();
            const lines = text.replace(/\uFEFF/g, '').split('\n');

            lines.forEach(line => {
                const domain = line.trim();
                if (domain) {
                    const root = getRootDomain(domain);
                    if (!existingRoots.has(root)) {
                        allDomains.add(domain);
                    }
                }
            });
        } catch (e) {
            console.warn(`Ошибка загрузки ${url}:`, e);
        }
    }

    return consolidateDomains([...allDomains]);
}

function logout() {
    fetch('/logout', {
        method: 'GET',
    })
    .then(response => {
        if (response.redirected) {
            window.location.href = response.url; // Перенаправление на страницу входа
        }
    })
    .catch(error => {
        console.error('Ошибка при выходе из системы:', error);
        openModal('Ошибка', 'Ошибка при выходе из системы');
    });
}

document.getElementById('change-password-form').addEventListener('submit', async (event) => {
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
        const response = await fetch('/change-password', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
            },
            body: JSON.stringify({
                currentPassword,
                newPassword,
            }),
        });

        const result = await response.json();

        if (result.success) {
            messageElement.textContent = 'Пароль успешно изменен.';
        } else {
            messageElement.textContent = result.error || 'Ошибка при смене пароля.';
        }
    } catch (error) {
        messageElement.textContent = 'Ошибка при отправке запроса.';
    }
});

updateStatus();