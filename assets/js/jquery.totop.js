$(document).ready(function () {
  var scrolled = 400;
  $(window).scroll(function() {
    if ( $(window).scrollTop() > scrolled ) {
      $('a.btt').fadeIn('slow');
    } else {
      $('a.btt').fadeOut('slow');
    }
  });

  $('a.btt').click(function() {
    $('html, body').animate({ scrollTop: 0 }, 700);
    return false;
  });
});
