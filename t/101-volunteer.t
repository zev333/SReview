#!/usr/bin/perl -w

use strict;
use warnings;

use Cwd 'abs_path';

BEGIN {
	if(exists($ENV{SREVIEWTEST_DB})) {
		open my $config, ">config.pm";
		print $config '$secret="foo";' . "\n";
		print $config '$dbistring=\'dbi:Pg:dbname=' . $ENV{SREVIEWTEST_DB} . '\';' . "\n";
		print $config '$volunteer_skip_user=\'operator@example.com\';' . "\n";
		print $config '$volunteer_release_after=\'48 hours\';' . "\n";
		close $config;
	}
}

use Test::More tests => 34;
use Test::Mojo;
use Mojo::File qw/path/;
use DBI;
use SReview::Config::Common;
use SReview::Db;

SKIP: {
	skip("Need a database to play with", 34) unless exists($ENV{SREVIEWTEST_DB});

	my $config = SReview::Config::Common::setup;
	SReview::Db::init($config);
	SReview::Db::selfdestruct(code => 0, init => 0);
	ok(SReview::Db::init($config), "Initializing the database was successful");
	my $dbh = DBI->connect($config->get('dbistring'), '', '', { RaiseError => 1, AutoCommit => 1 });
	$dbh->do("INSERT INTO rooms(id, name, altname, outputname) VALUES (1, 'room1', 'Room1', 'room1')");
	$dbh->do("INSERT INTO events(id, name, outputdir) VALUES(1, 'Test event', NULL)");
	for my $i (1..12) {
		$dbh->do("INSERT INTO talks(id, room, slug, starttime, endtime, title, event, upstreamid, state, progress) VALUES(?, 1, ?, '2017-11-10 17:00:00+00', '2017-11-10 17:30:00+00', ?, 1, ?, 'preview', 'waiting')", undef, $i, "talk-$i", "Talk $i", "up$i");
	}
	my $adduser = $dbh->prepare("INSERT INTO users(email, name, isadmin, isvolunteer, password) VALUES(?, ?, ?, ?, crypt('pw', gen_salt('bf', 8))) RETURNING id");
	my %uid;
	for my $u (['alice@example.com', 'Alice', 0, 1], ['bob@example.com', 'Bob', 0, 1], ['operator@example.com', 'Operator', 0, 1], ['admin@example.com', 'Admin', 1, 0]) {
		$adduser->execute(@$u);
		$uid{$u->[0]} = ($adduser->fetchrow_array)[0];
	}

	my $script = path(__FILE__)->dirname->child('..')->child('web')->child('sreview-web')->to_abs;
	my $top = path()->to_abs;
	symlink "../t", "web/t";
	chdir($script->dirname);
	my $claimed = sub {
		my $email = shift;
		return $dbh->selectcol_arrayref("SELECT id FROM talks WHERE reviewer = ? ORDER BY id", undef, $uid{$email});
	};

	my $alice = Test::Mojo->new($script);
	$alice->post_ok('/login_post' => form => { email => 'alice@example.com', pass => 'pw' })->status_is(302);
	$alice->get_ok('/volunteer/list')->status_is(200)->content_like(qr/want to review this talk/);
	is(scalar(@{$claimed->('alice@example.com')}), 5, "Alice gets five talks");

	# a talk that went back for re-cutting keeps its reviewer but does not take a slot
	my $recut = $claimed->('alice@example.com')->[0];
	$dbh->do("UPDATE talks SET state = 'cutting' WHERE id = ?", undef, $recut);
	$alice->get_ok('/volunteer/list')->status_is(200);
	is(scalar(@{$claimed->('alice@example.com')}), 6, "A talk being re-cut does not count against the limit");
	$dbh->do("UPDATE talks SET reviewer_seen = now() - '3 days'::interval WHERE id = ?", undef, $recut);
	$dbh->do("UPDATE talks SET state = 'preview' WHERE id = ?", undef, $recut);
	ok($dbh->selectrow_array("SELECT reviewer_seen > now() - '1 minute'::interval FROM talks WHERE id = ?", undef, $recut), "Returning to preview restarts the timer");

	# skipping hands the talk to the operator
	my $skip = $claimed->('alice@example.com')->[1];
	$alice->post_ok("/volunteer/skip/$skip")->status_is(302);
	is($dbh->selectrow_array("SELECT reviewer FROM talks WHERE id = ?", undef, $skip), $uid{'operator@example.com'}, "Skipped talk goes to the operator");
	$alice->post_ok("/volunteer/skip/$skip")->status_is(302);
	$alice->post_ok("/volunteer/skip/foo")->status_is(404);

	# opening the review page counts as activity
	my $active = $claimed->('alice@example.com')->[0];
	$dbh->do("UPDATE talks SET reviewer_seen = now() - '3 days'::interval WHERE reviewer IN (?, ?)", undef, $uid{'alice@example.com'}, $uid{'operator@example.com'});
	my $nonce = $dbh->selectrow_array("SELECT nonce FROM talks WHERE id = ?", undef, $active);
	$alice->get_ok("/r/$nonce")->status_is(200);

	# Bob takes over Alice's inactive talks, but not the one she opened, nor the skipped one
	my $bob = Test::Mojo->new($script);
	$bob->post_ok('/login_post' => form => { email => 'bob@example.com', pass => 'pw' })->status_is(302);
	$bob->get_ok('/volunteer/list')->status_is(200);
	is_deeply($claimed->('alice@example.com'), [$active], "Alice keeps only the talk she was active on");
	is($dbh->selectrow_array("SELECT reviewer FROM talks WHERE id = ?", undef, $skip), $uid{'operator@example.com'}, "The operator's talk is not released, even though the operator is a volunteer");

	# Alice can no longer submit a talk that went to Bob
	my $lost = $dbh->selectrow_array("SELECT id FROM talks WHERE reviewer = ? ORDER BY id LIMIT 1", undef, $uid{'bob@example.com'});
	my ($lost_nonce) = $dbh->selectrow_array("SELECT nonce FROM talks WHERE id = ?", undef, $lost);
	$alice->post_ok("/r/$lost_nonce/update" => form => { serial => 0, video_state => 'ok' })->status_is(409)->content_like(qr/assigned to another reviewer/);

	# talks claimed by a non-volunteer are released too
	my $admin = Test::Mojo->new($script);
	$admin->post_ok('/login_post' => form => { email => 'admin@example.com', pass => 'pw' });
	$admin->get_ok('/volunteer/list')->status_is(200);
	my $admin_talks = $claimed->('admin@example.com');
	$dbh->do("UPDATE talks SET reviewer_seen = now() - '3 days'::interval WHERE reviewer = ?", undef, $uid{'admin@example.com'});
	$bob->get_ok('/volunteer/list');
	is_deeply($claimed->('admin@example.com'), [], "Stale talks of an admin are released");

	chdir($top);
	unlink("web/t");
}

unlink("config.pm");
