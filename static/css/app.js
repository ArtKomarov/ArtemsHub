document.addEventListener("DOMContentLoaded", function() {
    // Initialize tsParticles with the configuration from particles.json
    tsParticles.load({
        id: "tsparticles",
        url: "/static/particles.json"
    });

    // Typewriter Effect
    const typewriterElement = document.getElementById('typewriter-text');
    const professions = ["Software Engineer", "ML Engineer", "Optimal Solution Enjoyer"];
    let professionIndex = 0;
    let charIndex = 0;
    let isDeleting = false;
    
    function type() {
        const currentProfession = professions[professionIndex];
        const currentText = isDeleting ? currentProfession.substring(0, charIndex--) : currentProfession.substring(0, charIndex++);
        typewriterElement.textContent = currentText;
    
        let typingSpeed = 100;
        if (isDeleting) {
            typingSpeed /= 2;
        }
    
        if (!isDeleting && charIndex === currentProfession.length + 1) {
            typingSpeed = 2000;
            isDeleting = true;
        } else if (isDeleting && charIndex === -1) {
            isDeleting = false;
            professionIndex = (professionIndex + 1) % professions.length;
            typingSpeed = 500;
        }
    
        setTimeout(type, typingSpeed);
    }
    type();
});