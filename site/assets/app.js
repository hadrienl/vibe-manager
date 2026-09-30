// The only script of the landing page: the language menu goes to the same page in the chosen
// language, and remembers the choice for the root page's redirect.
(function () {
  var menu = document.getElementById("lang");
  if (!menu) return;
  menu.addEventListener("change", function () {
    var option = menu.options[menu.selectedIndex];
    try { localStorage.setItem("vm-lang", option.value); } catch (e) {}
    location.href = option.dataset.href + location.hash;
  });
})();

// A screenshot opens in the appearance it is shown in.
document.addEventListener("click", function (event) {
  var link = event.target.closest && event.target.closest(".doc-shot a");
  var image = link && link.querySelector("img");
  if (image && image.currentSrc) link.href = image.currentSrc;
});
