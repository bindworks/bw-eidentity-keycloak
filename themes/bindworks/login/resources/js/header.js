// Links in the top bar: logo -> www.bindworks.eu (new tab), "Kontakt" button -> e-mail.
document.addEventListener("DOMContentLoaded", () => {
    const header = document.getElementById("kc-header");
    if (!header) {
        return;
    }

    const logo = document.createElement("a");
    logo.className = "bw-logo-link";
    logo.href = "https://www.bindworks.eu";
    logo.target = "_blank";
    logo.rel = "noopener";
    logo.setAttribute("aria-label", "Bindworks");

    const contact = document.createElement("a");
    contact.className = "bw-contact";
    contact.href = "mailto:serviceadmin@bindworks.eu";
    contact.innerHTML = 'Kontakt<svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true">'
        + '<path d="M9.3 6.3a1 1 0 0 1 1.4 0l5 5a1 1 0 0 1 0 1.4l-5 5a1 1 0 1 1-1.4-1.4L13.6 12 9.3 7.7a1 1 0 0 1 0-1.4z" fill="currentColor"/></svg>';

    header.append(logo, contact);

    // language switcher like on the website: "CS" / "EN" instead of "Czech (Čeština)"
    const languages = document.getElementById("login-select-toggle");
    if (languages) {
        const utilities = languages.closest(".pf-v5-c-login__main-header-utilities");
        utilities?.classList.add("bw-lang");

        const options = [...languages.options].map((option) => ({
            url: option.value,
            label: option.textContent.trim(),
            tag: new URL(option.value, location.href).searchParams.get("kc_locale") || "",
            selected: option.selected,
        }));

        if (options.length === 2 && utilities) {
            // two languages: like the website, the pill shows the other language and switches to it
            const other = options.find((option) => !option.selected) || options[0];
            const link = document.createElement("a");
            link.className = "bw-lang-link";
            link.href = other.url;
            link.hreflang = other.tag;
            link.title = other.label;
            link.setAttribute("aria-label", other.label);
            link.textContent = other.tag.toUpperCase();
            utilities.replaceChildren(link);
        } else {
            for (const [i, option] of options.entries()) {
                languages.options[i].title = option.label;
                languages.options[i].textContent = option.tag.toUpperCase();
            }
        }
    }
});
