package Connector::Email;
use Moose;
use Data::Dumper;
use MIME::Base64;
extends 'Connector';

our $Description = 'Send email';
sub description { return $Description }
sub admin_required { return 0 }

has 'query' => (is => 'rw', isa => 'Query', required => 1);

sub BUILD {
	my $self = shift;
	$self->api->log->debug('got results to alert on: ' . Dumper($self->query->results));
		
	unless ($self->query->results->total_records){
		$self->api->log->info('No results for query');
		return 0;
	}
	
	my @to = ($self->user->email);
	# Allow admin or none/local auth to override recipient
	if ($self->user->is_admin or $self->api->conf->get('auth/none') or $self->api->conf->get('auth/local')){
		if (scalar @{ $self->args }){
			@to = @{ $self->args };
		}
	}
	
	my $headers = {
		To => join(', ', @to),
		From => $self->api->conf->get('email/display_address') ? $self->api->conf->get('email/display_address') : 'system',
		Subject => $self->api->conf->get('email/subject') ? $self->api->conf->get('email/subject') : 'system',
	};
	my $body;
	if ($self->api->conf->get('email/include_data')){
		if ($self->query->has_groupby){
			$body = $self->query->results->TO_JSON();
		}
		else {
			$body = 'Total Results: ' . $self->query->results->total_results . "\r\n";
			foreach my $row ($self->query->results->all_results){
				$body .= $row->{msg} . "\r\n";
			}
		}	
	}
	else {
		$body = sprintf('%d results for query %s', $self->query->results->records_returned, $self->query->query_string) .
			"\r\n" . sprintf('%s/get_results?qid=%d&hash=%s', 
				$self->api->conf->get('email/base_url') ? $self->api->conf->get('email/base_url') : 'http://localhost',
				$self->query->qid,
				$self->api->get_hash($self->query->qid),
		);
	}
	my ($query, $sth);
	$query = 'SELECT UNIX_TIMESTAMP(last_alert) AS last_alert, alert_threshold FROM query_schedule WHERE id=?';
	$sth = $self->api->db->prepare($query);
	$sth->execute($self->query->schedule_id);
	my $row = $sth->fetchrow_hashref;
	if ((time() - $row->{last_alert}) < $row->{alert_threshold}){
		$self->api->log->warn('Not alerting because last alert was at ' . (scalar localtime($row->{last_alert})) 
			. ' and threshold is at ' . $row->{alert_threshold} . ' seconds.' );
		return;
	}
	else {
		$query = 'UPDATE query_schedule SET last_alert=NOW() WHERE id=?';
		$sth = $self->api->db->prepare($query);
		$sth->execute($self->query->schedule_id);
	}
	
	$self->api->send_email({ headers => $headers, body => $body});
	
	# Check to see if we saved the results previously
	$query = 'SELECT qid FROM saved_results WHERE qid=?';
	$sth = $self->api->db->prepare($query);
	$sth->execute($self->query->qid);
	$row = $sth->fetchrow_hashref;
	unless ($row){
		# Save the results
		$self->query->comments('Scheduled Query ' . $self->query->schedule_id);
		$self->api->save_results($self->query->TO_JSON);
	}
}

1