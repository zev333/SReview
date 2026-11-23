package SReview::Web::Controller::Volunteer;

use Mojo::Base 'Mojolicious::Controller';

sub skip_user_id {
	my $c = shift;
	my $email = $c->srconfig->get('volunteer_skip_user');
	return undef unless defined($email);
	my $st = $c->dbh->prepare("SELECT id FROM users WHERE email = ?");
	$st->execute($email);
	return undef unless $st->rows == 1;
	return ($st->fetchrow_array)[0];
}

sub list {
	my $c = shift;
	my @talks;
	my $skip_user = $c->skip_user_id;
	my $dbh = $c->dbh;
	$dbh->begin_work;
	eval {
		my $release_after = $c->srconfig->get('volunteer_release_after');
		if(defined($release_after)) {
			my $release = $dbh->prepare("UPDATE talks SET reviewer = NULL, reviewer_seen = NULL WHERE state = 'preview' AND reviewer IS NOT NULL AND reviewer <> ? AND reviewer IS DISTINCT FROM ? AND COALESCE(reviewer_seen, '-infinity') < now() - ?::interval");
			$release->execute($c->session->{id}, $skip_user, $release_after);
		}
		my $already = $dbh->prepare("SELECT nonce, title, id, state FROM talks WHERE reviewer = ? AND state <= 'preview' ORDER BY state DESC, id");
		my $new = $dbh->prepare("SELECT nonce, title, id, state FROM talks WHERE reviewer IS NULL AND state = 'preview'::talkstate LIMIT ? FOR UPDATE SKIP LOCKED");
		my $claim = $dbh->prepare("UPDATE talks SET reviewer = ?, reviewer_seen = now() WHERE id = ?");
		$already->execute($c->session->{id});
		my $count = 0;
		while(my @row = $already->fetchrow_array) {
			push @talks, [ @row ];
			# talks that are being re-cut do not take up a slot
			$count++ if $row[3] eq 'preview';
		}
		if($count < 5) {
			$new->execute(5 - $count);
			while(my @row = $new->fetchrow_array) {
				$claim->execute($c->session->{id}, $row[2]);
				push @talks, [ @row ];
			}
		}
		$dbh->commit;
		1;
	} or do {
		my $err = $@;
		eval { $dbh->rollback };
		die $err;
	};
	$c->stash(talks => \@talks);
	$c->stash(can_skip => defined($skip_user) ? 1 : 0);
	$c->stash(layout => 'admin');
}

sub skip {
	my $c = shift;
	my $skip_user = $c->skip_user_id;
	if(!defined($skip_user)) {
		$c->res->code(403);
		return $c->render(text => "Skipping talks is not enabled");
	}
	my $st = $c->dbh->prepare("UPDATE talks SET reviewer = ?, reviewer_seen = now() WHERE id = ? AND reviewer = ? AND state = 'preview'");
	$st->execute($skip_user, $c->stash('talk'), $c->session->{id});
	if($st->rows == 0) {
		$c->flash(msg => "This talk is no longer assigned to you, or is not waiting for review.");
	}
	$c->redirect_to('/volunteer/list');
}

1;
