using System;
using System.Linq;
using System.Threading.Tasks;
using FluentAssertions;
using Raven.Abstractions.Extensions;
using Raven.Client;
using Raven.Client.Document;
using Raven.Client.Linq;
using Raven.Client.Embedded;
using Raven.Client.Indexes;
using Xunit;
namespace Raven.SmokeTests
{
    public class SmokeTests : IDisposable
    {
        private readonly IDocumentStore _documentStore;

        public SmokeTests()
        {
            _documentStore = new EmbeddableDocumentStore
            {
                Conventions = {DefaultQueryingConsistency = ConsistencyOptions.AlwaysWaitForNonStaleResultsAsOfLastWrite},
                   RunInMemory = true,
                Configuration =
                {
                    Settings =
                    {
                        {"Raven/AssembliesDirectory", "~/assemblies-" + Guid.NewGuid().ToString("n")}
                    },
                     
                }
            }.Initialize();

            Raven.Abstractions.Logging.LogManager.CurrentLogManager = new Raven.Abstractions.Logging.LogProviders.NLogLogManager();
        }

        private async Task Seed()
        {
            var orderCount = 128;
            var customerCount = 32;

            var companies = Enumerable.Range(1, customerCount)
                .Select(id => new Company
                {
                    Id = "Company/" + id
                });

            var orders = Enumerable.Range(1, orderCount)
                .Select(id => new Order
                {
                    Company = "Company/" + ((id % customerCount) + 1),
                    Freight = id * 2,
                    Id = "Order/" + id
                });


            using (var operation = _documentStore.BulkInsert())
            {
                companies.OfType<object>()
                    .Union(orders)
                    .ForEach(x => operation.Store(x));

                await operation.DisposeAsync();
            }

        }

        [Fact]
        public async Task can_save_and_load()
        {
            await Seed();

            using (var session = _documentStore.OpenAsyncSession())
            {
                var document = await session.LoadAsync<Order>("Order/1");

                document.Freight.Should().Be(2);
            }
        }

        [Fact]
        public async Task dynamic_query()
        {
            await Seed();

            using (var session = _documentStore.OpenAsyncSession())
            {
                var results = await (session.Query<Order>()
                    .Where(x => x.Freight > 100) // remember to add `Raven.Client.Linq` namespace
                    .ToListAsync());

                results.Count.Should().Be(78);
            }
        }

        [Fact]
        public async Task map()
        {
            await new Orders_ByFreight().ExecuteAsync(_documentStore);

            await Seed();

            using (var session = _documentStore.OpenAsyncSession())
            {
                var results = await (session.Query<Order, Orders_ByFreight>()
                    .Where(x => x.Freight > 100) // remember to add `Raven.Client.Linq` namespace
                    .ToListAsync());

                results.Count.Should().Be(78);
            }
        }

        [Fact]
        public async Task map_reduce()
        {
            await new Orders_ByCompany().ExecuteAsync(_documentStore);

            await Seed();

            using (var session = _documentStore.OpenAsyncSession())
            {
                var results = await (session.Query<Orders_ByCompany.Result, Orders_ByCompany>()
                    .Where(x => x.Count > 0) // remember to add `Raven.Client.Linq` namespace
                    .ToListAsync());

                results.Count.Should().BeGreaterThan(0);
            }

        }

        [Fact]
        public async Task simple_transformer()
        {
            await new Orders_Company().ExecuteAsync(_documentStore);

            await Seed();

            using (var session = _documentStore.OpenAsyncSession())
            {
                var results = await (session.Query<Order>()
                    .Where(x => x.Freight > 100) // remember to add `Raven.Client.Linq` namespace
                    .TransformWith<Orders_Company, string>()
                    .ToListAsync());

                results.Count.Should().Be(78);
            }

        }

        [Fact]
        public async Task complicated_transformers()
        {
            await new GetNode.Transformer().ExecuteAsync(_documentStore);
            var count = 28;
            using (var session = _documentStore.OpenAsyncSession())
            {
                foreach (var i in Enumerable.Range(1, count))
                {
                    var p = new GetNode.NodeProjection()
                    {
                        Id = "node/" + i,
                        Name = "Node " + i,
                        References = new[]
                        {
                            "node/" + (i-1)
                        }
                    };
                    await session.StoreAsync(p);
                }
                await session.SaveChangesAsync();
            }

            using (var session = _documentStore.OpenAsyncSession())
            {
                foreach (var i in Enumerable.Range(1, count))
                {
                    var node = await session.LoadAsync<GetNode.NodeProjection>("node/" + i);
                }
            }
            using (var session = _documentStore.OpenAsyncSession())
            {
                foreach (var i in Enumerable.Range(1, count))
                {
                    var node = await session.LoadAsync<GetNode.Transformer, GetNode.NodeProjection>("node/" + i);
                }
            }

        }

        public void Dispose()
        {
            _documentStore.Dispose();
        }

        internal class Company
        {
            public string Id { get; set; }
        }

        internal class Order
        {
            public string Id { get; set; }

            public string Company { get; set; }

            public int Freight { get; set; }
        }

        internal class Orders_ByFreight : AbstractIndexCreationTask<Order>
        {
            public Orders_ByFreight()
            {
                Map = docs => from doc in docs
                    select new {doc.Freight};
            }
        }

        internal class Orders_ByCompany : AbstractIndexCreationTask<Order, Orders_ByCompany.Result>
        {
            internal class Result
            {
                public int Count { get; set; }

                public string Company { get; set; }
            }

            public Orders_ByCompany()
            {
                Map = docs => from doc in docs
                    select new {Count = 1, doc.Company};

                Reduce = results => from result in results
                    group result by result.Company
                    into g
                    select new
                    {
                        Company = g.Key,
                        Count = g.Sum(x => x.Count)
                    };
            }
        }

        internal class Orders_Company : AbstractTransformerCreationTask<Order>
        {
            public Orders_Company()
            {
                TransformResults = results => from result in results select result.Company;
            }
        }
    }
}