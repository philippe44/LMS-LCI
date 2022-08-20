package Plugins::LCI::API;

use strict;

use Digest::MD5 qw(md5_hex);
use JSON::XS::VersionOneAndTwo;
use List::Util qw(min max first);

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
	
use Slim::Networking::Async::HTTP;

use constant API_URL => "http://api.tf1info.fr";

my $prefs = preferences('plugin.LCI');
my $log   = logger('plugin.LCI');
my $cache = Slim::Utils::Cache->new();

sub search	{
	my ( $page, $cb, $params ) = @_;
	my $url = API_URL . $page;
	my $cacheKey = md5_hex($url);
	my $cached;
	
	$log->debug("wanted url: $url");
	
	if ( !$prefs->get('no_cache') && ($cached = $cache->get($cacheKey)))  {
		main::INFOLOG && $log->info("Returning cached data for: $url");
		$cb->($cached);
		return;
	}

	Slim::Networking::SimpleAsyncHTTP->new(
	
		sub {
			my $response = shift;
			my $result = eval { decode_json($response->content) };
			
			$result ||= {};
			
			$cache->set($cacheKey, $result, 3600);
			
			$cb->($result);
		},

		sub {
			$log->error($_[1]);
			$cb->( { error => $_[1] } );
		},

	)->get($url);
			
	
}


1;