use CGI::Simple;
use Test::MockModule;
use Test::MockTime qw(:all);
use FixMyStreet::TestMech;
use FixMyStreet::Script::Reports;
use Catalyst::Test 'FixMyStreet::App';

# disable info logs for this test run
FixMyStreet::App->log->disable('info');
END { FixMyStreet::App->log->enable('info'); }

set_fixed_time('2019-10-16T17:00:00Z'); # Out of hours

use_ok 'FixMyStreet::Cobrand::Bexley';
use_ok 'FixMyStreet::Geocode::Bexley';

my $ukc = Test::MockModule->new('FixMyStreet::Cobrand::UKCouncils');
$ukc->mock('lookup_site_code', sub {
    my ($self, $row, $buffer) = @_;
    is $row->latitude, 51.408484, 'Correct latitude';
    return "Road ID";
});

FixMyStreet::override_config {
    COBRAND_FEATURES => {
        contact_email => {
            bexley => 'foo@bexley',
        }
    },
}, sub {
    my $cobrand = FixMyStreet::Cobrand::Bexley->new;
    like $cobrand->contact_email, qr/bexley/;
    is $cobrand->on_map_default_status, 'open';
    is_deeply $cobrand->disambiguate_location->{bounds}, [ 51.408484, 0.074653, 51.515542, 0.2234676 ];
};

my $mech = FixMyStreet::TestMech->new;


my $body = $mech->create_body_ok(2494, 'London Borough of Bexley', {
    send_method => 'Open311', api_key => 'key', 'endpoint' => 'e', 'jurisdiction' => 'j' }, { cobrand => 'bexley' });
$mech->create_contact_ok(body_id => $body->id, category => 'Abandoned and untaxed vehicles', email => "ConfirmABAN");
$mech->create_contact_ok(body_id => $body->id, category => 'Lamp post', email => "StreetLightingLAMP");
$mech->create_contact_ok(body_id => $body->id, category => 'Gulley covers', email => "GULL");
$mech->create_contact_ok(body_id => $body->id, category => 'Damaged road', email => "ROAD");
$mech->create_contact_ok(body_id => $body->id, category => 'Flooding in the road', email => "ConfirmFLOD");
$mech->create_contact_ok(body_id => $body->id, category => 'Flytipping', email => "UniformFLY");
my $da = $mech->create_contact_ok(body_id => $body->id, category => 'Dead animal', email => "ANIM");
$mech->create_contact_ok(body_id => $body->id, category => 'Street cleaning and litter', email => "STREET");
$mech->create_contact_ok(body_id => $body->id, category => 'Something dangerous', email => "DANG", group => 'Danger things');

$da->set_extra_fields({
    code => 'message',
    datatype => 'text',
    description => 'Please visit http://public.example.org/dead_animals',
    order => 100,
    required => 'false',
    variable => 'false',
});
$da->update;

FixMyStreet::override_config {
    ALLOWED_COBRANDS => [ 'bexley' ],
    MAPIT_URL => 'http://mapit.uk/',
    STAGING_FLAGS => { send_reports => 1, skip_checks => 0 },
    COBRAND_FEATURES => {
        open311_email => { bexley => {
            p1 => 'p1@bexley',
            p1confirm => 'p1confirm@bexley',
            lighting => 'thirdparty@notbexley.example.com,another@notbexley.example.com',
            outofhours => 'outofhours@bexley,ooh2@bexley',
            flooding => 'flooding@bexley',
            eh => 'eh@bexley',
        } },
        staff_url => { bexley => {
            'Dead animal' => [ 'message', 'http://public.example.org/dead_animals', 'http://staff.example.org/dead_animals' ],
            'Missing category' => [ 'message', 'http://public.example.org/dead_animals', 'http://staff.example.org/dead_animals' ]
        } },
        category_groups => { bexley => 1 },
    },
}, sub {

    subtest 'cobrand displays council name' => sub {
        ok $mech->host("bexley.fixmystreet.com"), "change host to bexley";
        $mech->get_ok('/');
        $mech->content_contains('Bexley');
    };

    subtest 'cobrand displays council name' => sub {
        $mech->get_ok('/reports/Bexley');
        $mech->content_contains('Bexley');
    };

    subtest 'cobrand does not show Environment Agency categories' => sub {
        my $bexley = $mech->create_body_ok(2494, 'London Borough of Bexley');
        my $environment_agency = $mech->create_body_ok(2494, 'Environment Agency');
        my $odour_contact = $mech->create_contact_ok(body_id => $environment_agency->id, category => 'Odour', email => 'ics@example.com');
        my $tree_contact = $mech->create_contact_ok(body_id => $bexley->id, category => 'Trees', email => 'foo@bexley');
        $mech->get_ok("/report/new/ajax?latitude=51.466707&longitude=0.181108");
        $mech->content_contains('Trees');
        $mech->content_lacks('Odour');
    };

    subtest 'not opted in cobrand does not show assignee filter on admin/reports page' => sub {
        my $bexley = $mech->create_body_ok(2494, 'London Borough of Bexley');
        my $admin_user = $mech->create_user_ok('adminuser@example.com', name => 'An admin user', from_body => $bexley, is_superuser => 1);
        $mech->create_problems_for_body( 1, $bexley->id, 'Assignee', {
        category => 'Zebra Crossing',
        extra => {
            contributed_as => 'another_user',
            contributed_by => $admin_user->id,
            },
        });
        $mech->log_in_ok($admin_user->email);
        $mech->get_ok('/admin/reports');
        $mech->content_lacks('Assignee</option>');
        $mech->delete_problems_for_body($bexley->id);
    };

    my $report;
    foreach my $test (
        { category => 'Abandoned and untaxed vehicles', email => ['p1confirm'], code => 'ConfirmABAN',
            extra => { 'name' => 'burnt', description => 'Was it burnt?', 'value' => 'Yes' } },
        { category => 'Abandoned and untaxed vehicles', code => 'ConfirmABAN',
            extra => { 'name' => 'burnt', description => 'Was it burnt?', 'value' => 'No' } },
        { category => 'Dead animal', email => ['p1', 'outofhours', 'ooh2'], code => 'ANIM' },
        { category => 'Something dangerous', email => ['p1', 'outofhours', 'ooh2'], code => 'DANG',
            extra => { 'name' => 'dangerous', description => 'Was it dangerous?', 'value' => 'Yes' } },
        { category => 'Something dangerous', code => 'DANG',
            extra => { 'name' => 'dangerous', description => 'Was it dangerous?', 'value' => 'No' } },
        { category => 'Street cleaning and litter', email => ['p1', 'outofhours', 'ooh2'], code => 'STREET',
            extra => { 'name' => 'reportType', description => 'Type of report', 'value' => 'Oil spillage' } },
        { category => 'Gulley covers', email => ['p1', 'outofhours', 'ooh2'], code => 'GULL',
            extra => { 'name' => 'reportType', description => 'Type of report', 'value' => 'Cover missing' } },
        { category => 'Gulley covers', code => 'GULL',
            extra => { 'name' => 'reportType', description => 'Type of report', 'value' => 'Cover damaged' } },
        { category => 'Gulley covers', email => ['p1', 'outofhours', 'ooh2'], code => 'GULL',
            extra => { 'name' => 'dangerous', description => 'Was it dangerous?', 'value' => 'Yes' } },
        { category => 'Damaged road', code => 'ROAD', email => ['p1', 'outofhours', 'ooh2'],
            extra => { 'name' => 'dangerous', description => 'Was it dangerous?', 'value' => 'No' } },
        { category => 'Damaged road', code => 'ROAD', email => ['p1', 'outofhours', 'ooh2'],
            extra => { 'name' => 'dangerous', description => 'Was it dangerous?', 'value' => 'Yes' } },
        { category => 'Lamp post', code => 'StreetLightingLAMP', email => ['thirdparty', 'another'],
            extra => { 'name' => 'dangerous', description => 'Was it dangerous?', 'value' => 'No' } },
        { category => 'Lamp post', code => 'StreetLightingLAMP', email => ['thirdparty', 'another'],
            extra => { 'name' => 'dangerous', description => 'Was it dangerous?', 'value' => 'Yes' } },
        { category => 'Flytipping', code => 'UniformFLY', email => ['eh'] },
        { category => 'Flooding in the road', code => 'ConfirmFLOD', email => ['flooding'] },
    ) {
        ($report) = $mech->create_problems_for_body(1, $body->id, 'On Road', {
            category => $test->{category}, cobrand => 'bexley',
            latitude => 51.408484, longitude => 0.074653, areas => '2494',
        });
        if ($test->{extra}) {
            $report->set_extra_fields(ref $test->{extra} eq 'ARRAY' ? @{$test->{extra}} : $test->{extra});
            $report->update;
        }

        subtest 'NSGRef and correct email config' => sub {
            FixMyStreet::Script::Reports::send();
            my $req = Open311->test_req_used;
            my $c = CGI::Simple->new($req->content);
            is $c->param('service_code'), $test->{code};
            if ($test->{code} =~ /Confirm/) {
                is $c->param('attribute[site_code]'), 'Road ID';
            } elsif ($test->{code} =~ /Uniform/) {
                is $c->param('attribute[uprn]'), 'Road ID';
            } else {
                is $c->param('attribute[NSGRef]'), 'Road ID';
            }

            if (my $t = $test->{email}) {
                my @emails = $mech->get_email;
                # User is getting a report_sent_confirmation_email now and the ordering is random
                my ($email) = grep { $mech->get_text_body_from_email($_) =~ /Dear London Borough of Bexley/ } @emails;
                $t = join('@[^@]*', @$t);
                is $email->header('From'), '"Test User" <do-not-reply@example.org>';
                like $email->header('To'), qr/^[^@]*$t@[^@]*$/;
                if ($test->{code} =~ /Confirm/) {
                    like $mech->get_text_body_from_email($email), qr/Site code: Road ID/;
                } elsif ($test->{code} =~ /Uniform/) {
                    like $mech->get_text_body_from_email($email), qr/UPRN: Road ID/;
                    like $mech->get_text_body_from_email($email), qr/Uniform ID: 248/;
                } else {
                    like $mech->get_text_body_from_email($email), qr/NSG Ref: Road ID/;
                }
                $mech->clear_emails_ok;
            } else {
                $mech->email_count_is(1);
            }
        };
    }

    subtest 'resend is disabled in admin' => sub {
        my $user = $mech->log_in_ok('super@example.org');
        $user->update({ from_body => $body, is_superuser => 1, name => 'Staff User' });
        $mech->get_ok('/admin/report_edit/' . $report->id);
        $mech->content_contains('View report on site');
        $mech->content_lacks('Resend report');
    };

    subtest "resending of reports by changing category" => sub {
        $mech->get_ok('/admin/report_edit/' . $report->id);
        $mech->submit_form_ok({ with_fields => { category => 'Damaged road' } });
        FixMyStreet::Script::Reports::send();
        my $req = Open311->test_req_used;
        my $c = CGI::Simple->new($req->content);
        is $c->param('service_code'), 'ROAD', 'Report resent in new category';

        $mech->submit_form_ok({ with_fields => { category => 'Gulley covers' } });
        FixMyStreet::Script::Reports::send();
        $req = Open311->test_req_used;
        is_deeply $req, undef, 'Report not resent';

        $mech->submit_form_ok({ with_fields => { category => 'Lamp post' } });
        FixMyStreet::Script::Reports::send();
        $req = Open311->test_req_used;
        $c = CGI::Simple->new($req->content);
        is $c->param('service_code'), 'StreetLightingLAMP', 'Report resent';
    };

    subtest 'extra CSV column present' => sub {
        $mech->get_ok('/dashboard?export=1');
        $mech->content_contains(',Category,Subcategory,');
        $mech->content_contains('"Danger things","Something dangerous"');
    };


    subtest 'testing special Open311 behaviour', sub {
        my @reports = $mech->create_problems_for_body( 1, $body->id, 'Test', {
            category => 'Flooding in the road', cobrand => 'bexley',
            latitude => 51.408484, longitude => 0.074653, areas => '2494',
            photo => '74e3362283b6ef0c48686fb0e161da4043bbcc97.jpeg,74e3362283b6ef0c48686fb0e161da4043bbcc97.jpeg',
        });
        my $report = $reports[0];

        FixMyStreet::Script::Reports::send();
        $report->discard_changes;
        ok $report->whensent, 'Report marked as sent';
        is $report->send_method_used, 'Open311', 'Report sent via Open311';
        is $report->external_id, 248, 'Report has right external ID';

        my $req = Open311->test_req_used;
        my $c = CGI::Simple->new($req->content);
        is $c->param('attribute[title]'), 'Test Test 1 for ' . $body->id, 'Request had correct title';
        is_deeply [ $c->param('media_url') ], [
            'http://bexley.example.org/photo/' . $report->id . '.0.full.jpeg?74e33622',
            'http://bexley.example.org/photo/' . $report->id . '.1.full.jpeg?74e33622',
        ], 'Request had multiple photos';
    };

    subtest 'anonymous update message' => sub {
        my $report = FixMyStreet::DB->resultset("Problem")->first;
        my $staffuser = $mech->create_user_ok('super@example.org');
        $mech->create_comment_for_problem($report, $report->user, 'Commenter', 'Normal update', 't', 'confirmed', 'confirmed');
        $mech->create_comment_for_problem($report, $staffuser, 'Staff user', 'Staff update', 'f', 'confirmed', 'confirmed');
        $mech->get_ok('/report/' . $report->id);
        $mech->content_contains('Posted by <strong>London Borough of Bexley</strong>');
        $mech->content_contains('Posted anonymously by a non-staff user');
    };

    subtest 'dead animal url changed for staff users' => sub {
        $mech->get_ok('/report/new/ajax?latitude=51.466707&longitude=0.181108');
        $mech->content_lacks('http://public.example.org/dead_animals');
        $mech->content_contains('http://staff.example.org/dead_animals');
        $mech->log_out_ok;
        $mech->get_ok('/report/new/ajax?latitude=51.466707&longitude=0.181108');
        $mech->content_contains('http://public.example.org/dead_animals');
        $mech->content_lacks('http://staff.example.org/dead_animals');
    };

    subtest 'private comments field' => sub {
        my $user = $mech->log_in_ok('cs@example.org');
        $user->update({ from_body => $body, is_superuser => 1, name => 'Staff User' });
        for my $permission ( 'contribute_as_another_user', 'contribute_as_anonymous_user', 'contribute_as_body' ) {
            $user->user_body_permissions->create({ body => $body, permission_type => $permission });
        }
        $mech->get_ok('/report/new?longitude=0.15356&latitude=51.45556');
        $mech->content_contains('name="private_comments"');
    };

    subtest 'reference number is shown' => sub {
        $mech->get_ok('/report/' . $report->id);
        $mech->content_contains('Report ref:&nbsp;' . $report->id);
    };

    subtest 'phishing warning is shown for new reports' => sub {
        $mech->log_out_ok;
        $mech->get_ok('/report/new?longitude=0.15356&latitude=51.45556&category=Lamp+post');
        $mech->content_contains('if asked for personal information, please do not respond');
    };

    subtest 'phishing warning is shown on report pages' => sub {
        $mech->get_ok('/report/' . $report->id);
        $mech->content_contains('if asked for personal information, please do not respond');
    };

    subtest "test ID in update email" => sub {
        $mech->clear_emails_ok;
        (my $report) = $mech->create_problems_for_body(1, $body->id, 'On Road', {
            category => 'Lamp post', cobrand => 'bexley',
            latitude => 51.408484, longitude => 0.074653, areas => '2494',
        });
        my $id = $report->id;
        my $user = $mech->log_in_ok('super@example.org');
        $user->update({ from_body => $body, is_superuser => 1, name => 'Staff User' });
        $mech->get_ok("/report/$id");
        $mech->submit_form_ok({
                with_fields => {
                    form_as => 'Another User',
                    username => 'test@email.com',
                    name => 'Test user',
                    update => 'Example update',
                },
        }, "submit details");
        like $mech->get_text_body_from_email, qr/The report's reference number is $id/, 'Update confirmation email contains id number';
};

subtest 'test ID in questionnaire email' => sub {
        $mech->clear_emails_ok;
        (my $report) = $mech->create_problems_for_body(1, $body->id, 'On Road', {
            category => 'Lamp post', cobrand => 'bexley',
            latitude => 51.408484, longitude => 0.074653, areas => '2494',
            whensent => DateTime->now->subtract(years => 1),
        });
        FixMyStreet::DB->resultset('Questionnaire')->send_questionnaires();
        my $text = $mech->get_text_body_from_email;
        my $id = $report->id;
        like $text, qr/The report's reference number is $id/, 'Questionnaire email contains id number';
    };
};

subtest 'nearest road returns correct road' => sub {
    my $cobrand = FixMyStreet::Cobrand::Bexley->new;
    my $cfg = {
        accept_feature => sub { 1 },
        property => 'fid',
    };
    my $features = [
        { geometry => { type => 'Polygon' } },
        { geometry => { type => 'MultiLineString',
            coordinates => [ [ [ 545499, 174361 ], [ 545420, 174359 ], [ 545321, 174352 ] ] ] },
          properties => { fid => '20101226' } },
        { geometry => { type => 'LineString',
            coordinates => [ [ 545420, 174359 ], [ 545419, 174375 ], [ 545418, 174380 ], [ 545415, 174391 ] ] },
          properties => { fid => '20100024' } },
    ];
    is $cobrand->_nearest_feature($cfg, 545451, 174380, $features), '20101226';
};

my $geo = Test::MockModule->new('FixMyStreet::Geocode');
$geo->mock('cache', sub {
    my $typ = shift;
    return [] if $typ eq 'osm';
    return {
        features => [
            {
                properties => { ADDRESS => 'BRAMPTON ROAD', TOWN => 'BEXLEY' },
                geometry => { type => 'LineString', coordinates => [ [ 1, 2 ], [ 3, 4] ] },
            },
            {
                properties => { ADDRESS => 'FOOTPATH TO BRAMPTON ROAD', TOWN => 'BEXLEY' },
                geometry => { type => 'MultiLineString', coordinates => [ [ [ 1, 2 ], [ 3, 4 ] ], [ [ 5, 6 ], [ 7, 8 ] ] ] },
            },
        ],
    } if $typ eq 'bexley';
});

subtest 'split postcode overridden' => sub {
    my $data = FixMyStreet::Cobrand::Bexley->geocode_postcode('DA5 2BD');
    is_deeply $data, {
            latitude => 51.431244,
            longitude => 0.166464,
        }, 'override postcode';
};

subtest 'geocoder' => sub {
    my $c = ctx_request('/');
    my $results = FixMyStreet::Geocode::Bexley->string("Brampton Road", $c);
    is_deeply $results, { error => [
        {
            'latitude' => '49.766844',
            'longitude' => '-7.557122',
            'address' => 'Brampton Road, Bexley'
        }, {
            'address' => 'Footpath to Brampton Road, Bexley',
            'longitude' => '-7.557097',
            'latitude' => '49.766863'
        }
    ] };
};

subtest 'out of hours' => sub {
    my $lwp = Test::MockModule->new('LWP::UserAgent');
    $lwp->mock('get', sub {
        HTTP::Response->new(200, 'OK', [], <<EOF);
{
    "england-and-wales": {
        "events": [
            { "date": "2019-12-25", "title": "Christmas Day", "notes": "", "bunting": true }
        ]
    }
}
EOF
    });

    my $cobrand = FixMyStreet::Cobrand::Bexley->new;
    set_fixed_time('2019-10-16T12:00:00Z');
    is $cobrand->_is_out_of_hours(), 0, 'not out of hours in the day';
    set_fixed_time('2019-10-16T04:00:00Z');
    is $cobrand->_is_out_of_hours(), 1, 'out of hours early in the morning';
    set_fixed_time('2019-10-13T12:00:00Z');
    is $cobrand->_is_out_of_hours(), 1, 'out of hours at weekends';
    set_fixed_time('2019-12-25T12:00:00Z');
    is $cobrand->_is_out_of_hours(), 1, 'out of hours on bank holiday';
    set_fixed_time('2022-12-28T12:00:00Z');
    is $cobrand->_is_out_of_hours(), 1, 'out of hours on special day 2022';
};



done_testing();
