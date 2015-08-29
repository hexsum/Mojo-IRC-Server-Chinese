use lib "../lib/";
use Mojo::IRC::Server;
my $server = Mojo::IRC::Server->new(
    port        =>  6667,
    log_level   =>  "debug",
);
$server->run();
